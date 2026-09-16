# Open WebUI on Render

`render.yaml` in the repo root is the whole setup; this file explains the trade-offs
and the numbers behind it. Read the top of `render.yaml` first — it is applied
literally as infrastructure-as-code.

## The constraint

Render's free web service is **0.1 CPU / 512 MB RAM**, sleeps 15 min after the last
request, gets ~750 instance hours and ~500 build minutes per workspace per month, and
**cannot attach a persistent disk**. Open WebUI's published image
(`ghcr.io/open-webui/open-webui:main`) installs PyTorch, Whisper and
sentence-transformers and wants 1-2 GB, so on the free tier it is OOM-killed before it
serves a request. That is the whole reason this directory exists.

`Dockerfile` here builds a slim variant: same app, but
`backend/requirements-min.txt` + [`requirements-addons.txt`](requirements-addons.txt)
and no local model code. Measured on this repo in a clean-room venv (nothing pre-cached,
frontend stubbed out so only the Python side is measured):

| Check | Result |
| --- | --- |
| install size | 831 MB venv |
| time to `GET /health` = `{"status":true}` | 9 s |
| resident memory while idle | **349 MB** |
| signup → JWT → `/api/config` | works (admin created, 200s) |
| local RAG embeddings | `ModuleNotFoundError: sentence_transformers`, logged and skipped |

349 MB inside a 512 MB ceiling is a single-user demo, not a service. Watch for
`Container killed due to out of memory` in Render's logs; the usual triggers are a
second concurrent chat, WebSocket-heavy channels, uploading a file (chroma ingest), or
`UVICORN_WORKERS>1`.

## Deploy

1. Push a branch containing `render.yaml` and `deploy/` to GitHub.
2. Render → **New → Blueprint** → pick that repo/branch → Render reads the blueprint
   and lists one service, `open-webui`.
3. Expand the service and fill in the values Render asks for (`OPENAI_API_KEY`; anything
   marked `sync: false` is prompted because no value is committed in the blueprint).
4. Approve. That first deploy runs `npm ci` + `vite build` + `pip install` inside
   Render's build box. **On `plan: free` it will very likely die** with
   `FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory`
   — see [Build OOM](#build-oom-javascript-heap-out-of-memory) two sections down for
   the fix, which is a one-time CI build rather than a bigger number.
5. Open the `*.onrender.com` URL, sign up **once** — `ENABLE_SIGNUP=false` means the
   first admin account is the only one you can create, and
   `ENABLE_INITIAL_ADMIN_SIGNUP=true` is what keeps that first signup possible.

Port plumbing that makes step 4 work without touching the Dockerfile: Render injects
`PORT` (default 10000) and `backend/start.sh` honours it, so the container binds the
right socket; `EXPOSE 8080` in the Dockerfile is only the local-default hint.

## Making it not-a-toy

| Need | Change | Cost |
| --- | --- | --- |
| headroom for 2-3 users | `plan: 1c-2g` in `render.yaml` | $25/mo |
| chats/uploads survive redeploys | uncomment the `disk:` block (needs a paid plan) and keep `DATA_DIR=/app/backend/data` | $0.25/GB/mo |
| data durability on the **free** tier | point `DATABASE_URL` at a free external Postgres (Neon, ~0.5 GB) and `VECTOR_DB=pgvector` | $0 |
| stop paying build minutes per push | build the image in CI, deploy it as `runtime: image` (below) | $0 |
| a first request that isn't ~1-3 min | anything paid: free instances sleep, and a cold uvicorn boot on 0.1 CPU is slow | — |

### External Postgres instead of ephemeral SQLite

Add to `envVars`:

```yaml
- key: DATABASE_URL
  sync: false      # postgresql://user:pass@ep-xxx.neon.tech/neondb?sslmode=require
- key: VECTOR_DB
  value: pgvector  # optional; keeps RAG vectors in the same durable DB
```

`backend/open_webui/env.py` falls back to `sqlite:///$DATA_DIR/webui.db` when
`DATABASE_URL` is unset, so this is the one variable that decides whether your data
outlives a redeploy.

This image needs `psycopg2-binary` for that, and it is now in
`requirements-addons.txt` - it was missing, which made every external-Postgres
instruction in this file unusable. The reason is that `internal/db.py` builds two
engines: `create_async_engine()` on a URL rewritten to `postgresql+psycopg://` (psycopg
v3, present in `requirements-min.txt`) for all runtime queries, while the **sync**
engine - startup migrations, config loading, health checks - consumes the URL untouched,
so `postgresql://` resolves to SQLAlchemy's default **psycopg2** dialect. Before the fix
the container crashed at boot, because `config.py:run_migrations()` logs and re-raises.

### What MongoDB does here: nothing

`pymongo` appears in `backend/requirements.txt` under a "## Databases" heading, and the
app never imports it - there is no `MongoClient` anywhere in `backend/`. `DATABASE_URL` is
handed to SQLAlchemy, which speaks SQLite/Postgres; there is no code path that would talk
document-store protocol. So a Mongo instance will not become the chat/settings store, and
nothing will complain when you configure one.

The silent-skip is worth knowing about, because it looks like a half-working setup:

```python
# env.py - only used when EVERY one of these five is set
DB_VARS = {'db_type': DATABASE_TYPE, 'db_cred': ..., 'db_host': ..., 'db_port': ..., 'db_name': ...}
if all(DB_VARS.values()):
    DATABASE_URL = f'{db_type}://{db_cred}@{db_host}:{db_port}/{db_name}'
```

Any gap in that set - a password left blank, no `DATABASE_PORT` - and the whole branch is
skipped with no log line and no error: `DATABASE_URL` keeps its SQLite default and the
app quietly runs on the ephemeral file. Two more traps in the same area:

* `DATABASE_URL=""` (explicitly empty) is **not** the same as unset: `os.getenv` returns the
  empty string, the SQLite fallback never applies, and engine construction fails. Omit the
  variable, don't blank it.
* `postgres://` is accepted and rewritten to `postgresql://`, but a **pooled** Neon
  connection string is the one that works from Render (the serverless driver endpoint
  speaks HTTP, not libpq). Keep `?sslmode=require`.


### Build OOM: `JavaScript heap out of memory`

What the log looks like when you hit it:

```
[783:0x...] 73538 ms: Mark-Compact 3058.3 (3119.9) -> 3056.3 (3120.9) MB ...
FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory
ERROR: process "/bin/sh -c npm run build" did not complete successfully: exit code: 134
```

Exit 134 = SIGABRT from V8, and the numbers tell you which limit you hit: the heap died
just under the `--max-old-space-size` the build was given, so the *builder ran out of
addressable memory*, not the app. This is a build-time-only problem — the runtime image
needs 349 MB, nowhere near this.

Why it's this bad: `vite.config.ts` sets `build.sourcemap = true`, and the SvelteKit
rollup graph for this UI is large enough that **upstream forces `--max-old-space-size=12288`
on a 16 GB GitHub runner** to build it (`.github/workflows/docker.yaml` → "Prepare CI
Dockerfile"), and even the pip install path sets `--max-old-space-size=8192`
(`hatch_build.py`). So the practical floor here is ~8 GB of heap, not 3. A free Render
builder is below either number, and setting the cap above the machine's RAM just swaps a
V8 abort (exit 134) for a kernel OOM kill (exit 137).

Three ways out, best first:

1. **Build in CI, deploy the image** (recommended; also stops burning build minutes):
   copy `build-image.yaml` into `.github/workflows/`, let it push
   `ghcr.io/<owner>/<repo>-slim:latest`, then swap `render.yaml`'s three
   `runtime: docker` lines for:
   ```yaml
       runtime: image
       image: ghcr.io/<owner>/<repo>-slim:latest
   ```
   Caveat worth knowing up front, from Render's own docs: *"Services that use a
   prebuilt Docker image ... must be deployed manually"* — no auto-deploy on push.
   Trigger it from **Manual Deploy** in the dashboard, a [deploy
   hook](https://render.com/docs/deploy-hooks), or the API. You re-deploy when you want
   a new image, which for a demo is the right cadence anyway.
2. **Turn sourcemaps off and raise the heap** on whatever box you already have:
   ```bash
   docker build -f deploy/render/Dockerfile \
     --build-arg SOURCEMAP=off --build-arg NODE_MAX_OLD_SPACE_SIZE=12288 \
     -t open-webui-slim .
   ```
   `SOURCEMAP=off` is already the Dockerfile default (it patches `vite.config.ts`
   inside the build, not in git) — the heap is the one to raise, and it needs a builder
   with roughly 2x that much RAM free.
3. **Pay for a bigger builder**: bump the service to a paid plan and check its
   Settings for a build instance type before assuming the free box is the only option.

`SOURCEMAP=on` restores upstream behaviour (bigger image, slower build, debuggable
production JS) — nothing else in the image changes.

### Build by hand

If you'd rather not add a workflow, the same image from any machine with Docker:

```bash
docker build -f deploy/render/Dockerfile -t ghcr.io/<you>/open-webui-slim:latest .
docker push ghcr.io/<you>/open-webui-slim:latest   # public package = free on GHCR
```

`build-image.yaml` in this directory is exactly these two commands plus registry
caching, a paths filter so doc-only pushes don't rebuild, and amd64-only (Render is
x86_64, so QEMU and the multi-arch tax are skipped).

## What is missing versus the standard image, and why

| Feature | Status | Reason |
| --- | --- | --- |
| Chat via OpenAI-compatible APIs, users, groups, models/agents, notes, tools & actions, functions, PWA | ✅ | pure Python/JS, no model |
| Local RAG over uploaded documents | ❌ by default | needs `sentence-transformers` + torch (≈700 MB RSS). Set `RAG_EMBEDDING_MODEL` + `RAG_EMBEDDING_ENGINE=ollama`/`openai` to get it back via API embeddings |
| Hybrid search + reranking | ❌ | reranker is a torch model |
| Local Whisper STT / TTS | ❌ | `faster-whisper`/transformers not installed; use an API STT/TTS engine instead |
| Ollama models *inside* the container | ❌ | no GPU/room; point `OLLAMA_BASE_URL` at a remote Ollama instead |
| Playwright web loader | ❌ | browsers are ~500 MB; `WEB_LOADER_ENGINE` stays empty |
| any audio path that shells out to `ffmpeg` | ⚠️ | `pydub` logs `Couldn't find ffmpeg` at boot and audio features stay broken; harmless while STT/TTS are unset, install `ffmpeg` in the image if you enable an engine that needs it |
| `pyodide` client-side Python in artifacts | ⚠️ built, but heavy | the frontend build still fetches it; delete `static/pyodide` in a fork if you want ~100 MB less image |

## Keeping it awake (and what that costs)

Free services spin down after 15 minutes with no inbound HTTP request or WebSocket
message, and Render's ~1 minute wake estimate is optimistic for this app: a cold uvicorn
boot on 0.1 CPU takes minutes. So `deploy/render/keep-alive.yaml` (copy it into
`.github/workflows/`) pings `/health` on a schedule.

Before you turn it on, the arithmetic that decides everything:

* Render grants **750 free instance hours per workspace per month**, consumed only while
  a service is awake. A month is **720-744 hours**.
* One service pinned awake 24/7 therefore uses essentially the whole allowance, and a
  second one blows it.
* When the pool is empty Render **suspends every free web service in the workspace**
  until the next month. Pinging does not outsmart the cap; it spends it.

So: schedule 08:00-20:00 pings (~370 h/month, app warm when you're there) rather than
24/7, or accept cold starts. And two things that don't work:

* **Render's own Cron Job service** - cron jobs are not offered on `free` (the blueprint
  compute table for cron starts at `0.5c-512mb`, with no `free` row; only web services
  have one).
* **A `setInterval` that pings itself from inside the app** - the popular tutorial
  answer. It burns the same instance hours, and it's service-initiated outbound
  traffic, which Render has suspended free services over.

Cheaper tricks that are specific to this app:

* An open browser tab helps: the UI holds a WebSocket (`ENABLE_WEBSOCKET_SUPPORT`) and
  Render counts WebSocket traffic, so an actively used tab won't sleep. An idle tab may
  still let it nap.
* Ping `/health`, never `/` - it's a static JSON handler, no DB round trip, and doesn't
  pull page rendering into a 512 MB box.
* Waking is the cheap part; the real cost of sleeping here is the filesystem. Spin-down
  loses everything under `DATA_DIR`, so SQLite chats vanish whether or not you ping.
  `DATABASE_URL` at a free external Postgres is the fix; the pinger is cosmetics.
* Also note Render serves a `robots.txt` that disallows everything while a free service
  is asleep - if you ever wonder why a crawler saw nothing, that's why.

## Reply arrives but the UI never updates (refresh shows it)

Classic symptom: the message reaches the model, the reply is in the logs and in the
database, and the chat pane stays on "..." until you hard-reload. Nothing is broken in
the model path - the two directions of a chat use *different transports*:

| direction | transport |
| --- | --- |
| your message | plain `fetch` POST to `/api/chat/completions` (`generateOpenAIChatCompletion`) |
| every streamed delta | socket.io, `sio.emit('events', ..., room=f'user:{user_id}')` |

and the emit is guarded:

```python
# backend/open_webui/socket/main.py, in get_event_emitter()
if WEBSOCKET_MANAGER == 'redis' or room in sio.manager.rooms.get('/', {}):
    await sio.emit('events', {...}, room=room)
# no else: no matching room in this process = the event is dropped silently
```

The `save_to_chat` upsert right below it runs either way. So **any** condition that keeps
the socket from being registered in the *same process* as the completion produces exactly
"works, but only visible after a refresh". In order of how often each is the cause:

1. **`UVICORN_WORKERS` > 1 with no Redis.** The socket lives on one worker, the request is
   served by another, the room lookup misses, events vanish. Set it back to `1`, or give
   it a real fan-out bus: `WEBSOCKET_MANAGER=redis` + `REDIS_URL` (Render's free Key Value
   instance - 25 MB, no persistence - is adequate for this; it needs no durability, only
   reach).
2. **The WebSocket upgrade never completes.** With `ENABLE_WEBSOCKET_SUPPORT=true` both
   ends are websocket-only - the client sets `transports: ['websocket']` and the server
   `transports=['websocket'], allow_upgrades=False` - so there is no fallback to try.
   Set `ENABLE_WEBSOCKET_SUPPORT=false` in Render's Settings (no rebuild): socket.io then
   runs over HTTP long-polling, which gets through anything a WS upgrade can't, and the
   live delta path works again.
3. **A tab that outlived a restart, on a temporary chat.** The UI does resume in-flight
   generations after a reconnect (`handleSocketConnect` re-attaches via
   `getTaskIdsByChatId`), but that path returns early for temp chats and unsaved chats -
   so if you use temporary chats, a mid-stream blip is genuinely unrecoverable and a
   refresh is the only fix.

Confirm which one it is in about two minutes, before changing anything:

* DevTools → Console: the app logs `connected <socket.id>` when the socket is up and
  `connect_error <...>` when it isn't. No `connected` line = case 2.
* DevTools → Network → filter `ws` (or search `socket.io`): the request to
  `/ws/socket.io/?EIO=4&transport=websocket` must end at **101 Switching Protocols**.
  A 400/401/500 means the handshake is being refused; no request at all means the client
  never tried (then check `/api/config` -> `features.enable_websocket`).
* Render → Service → Environment: verify `UVICORN_WORKERS=1` is what is actually live, not
  just what the blueprint says - dashboard edits override the file.
* A throttling excuse can be ruled out from the code: `THROTTLE_INTERVAL = 0.15` caps
  deltas at ~6/sec, but the final `done` event is emitted unconditionally, so a merely
  slow box would still finish the message on its own. Nothing at all arriving means the
  event never reached the socket, not that it was rate-limited.

Also worth knowing: `WEBUI_SECRET_KEY` must be a set env var, not left to `start.sh`.
Without it, the key is generated into the container filesystem, and free-tier filesystems
are wiped on restart - every socket then fails its `auth: { token }` handshake while
already-issued HTTP cookies keep the rest of the app apparently fine. `render.yaml` sets
`generateValue` for exactly this reason.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| deploy log: `Container killed due to out of memory` | over 512 MB — see the paid row above, or set `ENABLE_WEBSOCKET_SUPPORT=false` |
| reply is generated (in the log and after a refresh) but never streams into the UI | the delta transport, not the model: see "Reply arrives but the UI never updates" above — `UVICORN_WORKERS=1` or `ENABLE_WEBSOCKET_SUPPORT=false` |
| "Service is starting" for minutes, then 502 | free tier cold start on 0.1 CPU; disable the health check path temporarily if Render aborts the deploy (Settings → Health Checks) |
| `npm run build` fails with `JavaScript heap out of memory`, exit 134 | the builder is too small for this frontend — [Build OOM](#build-oom-javascript-heap-out-of-memory) |
| `npm run build` killed with exit 137 instead | heap cap exceeded the box's RAM, so the kernel killed node; lower `NODE_MAX_OLD_SPACE_SIZE` or use a bigger builder |
| build succeeds but logs `WARNING: slim-image smoke test failed` | the optional import check tripped. It is warn-only by design (CI passes `SMOKE_STRICT=true`) but read the traceback above it: the container will probably crash on the same import at boot, and `requirements-addons.txt` is where the fix goes |
| `unable to open database file` from anything that imports the app | `DATA_DIR` must already exist - `env.py` creates it only on the pip-install path (`FROM_INIT_PY`), never for the `/app/backend` layout |
| the "What's new" / release-notes panel is empty | `/app/CHANGELOG.md` is missing: `env.py` falls back to an *empty* changelog, so a forgotten copy is silent rather than an error |
| build fails with `exceeded free build minutes` | 500 min/month shared per workspace → build in CI (`runtime: image`), and use `[skip render]` in commit messages or Settings → Build Filters so doc-only pushes don't rebuild |
| login works, then logs out a few minutes later | `WEBUI_SECRET_KEY` changed (a regenerated blueprint value does this) — set it explicitly |
| everything I did is gone next morning | expected on free: no disk. Use `DATABASE_URL` or a paid disk |
| boot crash `ModuleNotFoundError: No module named 'psycopg2'` after setting `DATABASE_URL` | image built before `psycopg2-binary` was added to `requirements-addons.txt` - rebuild, or drop `DATABASE_URL` until you do |
| `DATABASE_URL` seems ignored / data still lands in `webui.db` | if you set `DATABASE_TYPE`/`DATABASE_HOST`/... instead, all five are required or the block is skipped silently; or `DATABASE_URL` is set to the empty string, which defeats the SQLite fallback |
| chats and settings never persist at all | on `plan: free` there is no disk, so SQLite at `DATA_DIR` is wiped on every restart - that is the platform, not a bug; `DATABASE_URL` to external Postgres is the only durable $0 option |
| first visit is fine, second visitor times out | one sleeping instance + 0.1 CPU; this tier is single-user by construction |
