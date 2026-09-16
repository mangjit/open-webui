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
outlives a redeploy. `psycopg[binary]` is already in the requirements set, so no image
change is needed.

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
Dockerfile"). A free Render builder is far below that, and raising the number on a small
machine just swaps a V8 abort for a kernel OOM kill.

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

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| deploy log: `Container killed due to out of memory` | over 512 MB — see the paid row above, or set `ENABLE_WEBSOCKET_SUPPORT=false` |
| "Service is starting" for minutes, then 502 | free tier cold start on 0.1 CPU; disable the health check path temporarily if Render aborts the deploy (Settings → Health Checks) |
| `npm run build` fails with `JavaScript heap out of memory`, exit 134 | the builder is too small for this frontend — [Build OOM](#build-oom-javascript-heap-out-of-memory) |
| `npm run build` killed with exit 137 instead | heap cap exceeded the box's RAM, so the kernel killed node; lower `NODE_MAX_OLD_SPACE_SIZE` or use a bigger builder |
| the `import open_webui.main` check layer fails | the slim dependency set stopped covering startup imports (it prints the traceback now); add the missing module to `requirements-addons.txt`, pinned to the version in `backend/requirements.txt` |
| that same check fails with `unable to open database file` | `DATA_DIR` must exist before the app imports - `env.py` only creates it for pip installs, not this `/app/backend` layout |
| build fails with `exceeded free build minutes` | 500 min/month shared per workspace → build in CI (`runtime: image`), and use `[skip render]` in commit messages or Settings → Build Filters so doc-only pushes don't rebuild |
| login works, then logs out a few minutes later | `WEBUI_SECRET_KEY` changed (a regenerated blueprint value does this) — set it explicitly |
| everything I did is gone next morning | expected on free: no disk. Use `DATABASE_URL` or a paid disk |
| first visit is fine, second visitor times out | one sleeping instance + 0.1 CPU; this tier is single-user by construction |
