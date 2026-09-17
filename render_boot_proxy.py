#!/usr/bin/env python3
"""Render free-tier boot proxy for Open WebUI.

Problem: on Render's free tier (0.1 CPU) Open WebUI takes several minutes to
boot (Python imports + DB migrations), but uvicorn only opens its port AFTER
startup finishes — so Render declares the deploy dead ("Port scan timeout
reached") while the app is still healthily starting up.

Fix: this tiny proxy listens on $PORT in under a second so Render is happy,
launches the real app on 127.0.0.1:8081, and TCP-pipes all traffic to it once
ready. Pure byte piping => websockets, SSE streaming and keep-alive all work.
Before the backend is ready: /health returns 200 (deploy succeeds), every
other path gets a "warming up" page that auto-refreshes.
"""

import asyncio
import os
import signal
import sys

PUBLIC_PORT = int(os.getenv("PORT", "10000"))
APP_PORT = int(os.getenv("APP_PORT", "8081"))
APP_HOST = "127.0.0.1"

_backend_ready = asyncio.Event()
_child_proc = None  # asyncio subprocess handle
_shutting_down = False

HEALTH_BODY = b'{"status":true}'
WARMUP_PAGE = b"""<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="15">
<title>Warming up</title>
<style>body{font-family:system-ui,sans-serif;display:flex;min-height:100vh;margin:0;
align-items:center;justify-content:center;background:#0f172a;color:#e2e8f0;text-align:center}
small{color:#94a3b8}</style></head><body><div>
<h2>Open WebUI is warming up&hellip;</h2>
<p><small>Free-tier cold boot takes a few minutes. This page refreshes automatically.</small></p>
</div></body></html>"""


def log(*args):
    print("[proxy]", *args, flush=True)


async def backend_is_up():
    try:
        _, writer = await asyncio.wait_for(
            asyncio.open_connection(APP_HOST, APP_PORT), timeout=3
        )
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
        return True
    except (OSError, asyncio.TimeoutError):
        return False


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
        pass
    except Exception as exc:
        log("pipe error:", repr(exc))
    finally:
        try:
            writer.close()
        except Exception:
            pass


def _http_response(status, content_type, body, extra=""):
    head = (
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\n"
        f"Content-Length: {len(body)}\r\nConnection: close\r\n{extra}\r\n"
    ).encode("latin1")
    return head + body


async def close_writer(writer: asyncio.StreamWriter):
    try:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
    except Exception:
        pass


async def handle_client(reader: asyncio.StreamReader, cwriter: asyncio.StreamWriter):
    try:
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=15)
        except (asyncio.TimeoutError, asyncio.LimitOverrunError, asyncio.IncompleteReadError):
            await close_writer(cwriter)
            return
        try:
            request_line = head.split(b"\r\n", 1)[0].decode("latin1")
            parts = request_line.split()
            target = parts[1] if len(parts) > 1 else "/"
        except Exception:
            await close_writer(cwriter)
            return
        path = target.split("?", 1)[0]

        if not _backend_ready.is_set():
            if path == "/health":
                cwriter.write(_http_response("200 OK", "application/json", HEALTH_BODY))
                await cwriter.drain()
                await close_writer(cwriter)
                return
            if await backend_is_up():
                _backend_ready.set()
                log("backend is up -> piping traffic")
            else:
                cwriter.write(
                    _http_response(
                        "503 Service Unavailable",
                        "text/html; charset=utf-8",
                        WARMUP_PAGE,
                        extra="Retry-After: 15\r\n",
                    )
                )
                await cwriter.drain()
                await close_writer(cwriter)
                return

        # Backend ready: pure TCP pipe (websockets/SSE/keep-alive safe).
        try:
            breader, bwriter = await asyncio.wait_for(
                asyncio.open_connection(APP_HOST, APP_PORT), timeout=10
            )
        except (OSError, asyncio.TimeoutError):
            _backend_ready.clear()
            log("backend connection failed -> back to warmup mode")
            cwriter.write(
                _http_response(
                    "503 Service Unavailable",
                    "text/html; charset=utf-8",
                    WARMUP_PAGE,
                    extra="Retry-After: 15\r\n",
                )
            )
            await cwriter.drain()
            await close_writer(cwriter)
            return
        bwriter.write(head)  # forward the bytes we peeked at
        await bwriter.drain()
        await asyncio.gather(
            pipe(reader, bwriter),
            pipe(breader, cwriter),
        )
        await close_writer(cwriter)
    except Exception as exc:
        log("client handler error:", repr(exc))
        await close_writer(cwriter)


async def readiness_watcher():
    while not _backend_ready.is_set() and not _shutting_down:
        if await backend_is_up():
            _backend_ready.set()
            log("backend is up -> piping traffic")
            return
        await asyncio.sleep(3)


async def memory_monitor():
    """Log backend + container memory every 30s.

    On tiny boxes (Render free = 512 MB) the kernel OOM-killer can SIGKILL
    the whole container without a single log line. These readings make that
    visible: if RSS climbs to the cgroup max and the container restarts,
    it's OOM — not a hang.
    """
    while not _shutting_down:
        await asyncio.sleep(30)
        if _shutting_down:
            break
        try:
            info = []
            if _child_proc is not None and _child_proc.pid:
                try:
                    with open(f"/proc/{_child_proc.pid}/status") as f:
                        for line in f:
                            if line.startswith("VmRSS:"):
                                info.append(f"backend_RSS={line.split()[1]}kB")
                                break
                except FileNotFoundError:
                    info.append("backend_gone")
            read_cgroup = False
            for path, label in (
                ("/sys/fs/cgroup/memory.current", "used"),
                ("/sys/fs/cgroup/memory.max", "max"),
            ):
                try:
                    with open(path) as f:
                        info.append(f"cgroup_{label}={f.read().strip()}")
                        read_cgroup = True
                except FileNotFoundError:
                    pass
            if not read_cgroup:  # cgroup v1 fallback
                for path, label in (
                    ("/sys/fs/cgroup/memory/memory.usage_in_bytes", "used"),
                    ("/sys/fs/cgroup/memory/memory.limit_in_bytes", "max"),
                ):
                    try:
                        with open(path) as f:
                            info.append(f"cgroup_{label}={f.read().strip()}")
                    except FileNotFoundError:
                        pass
            log("mem:", " ".join(info) if info else "unavailable")
        except Exception as exc:
            log("mem monitor error:", repr(exc))


async def main():
    global _child_proc, _shutting_down
    loop = asyncio.get_running_loop()

    child_env = dict(os.environ)
    child_env["PORT"] = str(APP_PORT)
    child_env["HOST"] = APP_HOST
    log(f"starting Open WebUI backend on {APP_HOST}:{APP_PORT} ...")
    _child_proc = await asyncio.create_subprocess_exec(
        "bash",
        "/app/backend/start.sh",
        cwd="/app/backend",
        env=child_env,
        stdout=None,  # inherit -> app logs show up in Render logs
        stderr=None,
    )

    def _on_term(*_args):
        global _shutting_down
        if _shutting_down:
            return
        _shutting_down = True
        log("received stop signal -> terminating backend ...")
        try:
            if _child_proc is not None and _child_proc.returncode is None:
                _child_proc.terminate()
        except ProcessLookupError:
            pass

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, _on_term)
        except NotImplementedError:
            signal.signal(sig, lambda *_a: _on_term())

    server = await asyncio.start_server(handle_client, "0.0.0.0", PUBLIC_PORT, limit=1024 * 1024)
    log(f"proxy listening on 0.0.0.0:{PUBLIC_PORT} (deploy will go live now)")

    watcher = asyncio.create_task(readiness_watcher())
    monitor = asyncio.create_task(memory_monitor())
    rc = await _child_proc.wait()  # backend exited (crash or stop)
    _shutting_down = True
    watcher.cancel()
    monitor.cancel()
    server.close()
    await server.wait_closed()
    log(f"backend exited with code {rc} -> proxy exiting")
    sys.exit(rc if isinstance(rc, int) else 1)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
