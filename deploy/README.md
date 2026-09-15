# Free / low-cost deployment kit

Two ways to get this repo running off a box you own, plus the honest numbers behind
each. Neither is production-grade, and the platform limits are the reason.

| Directory | What it is | Build | Notes |
| --- | --- | --- | --- |
| [`render/`](render/README.md) | `render.yaml` blueprint + a slim `Dockerfile` sized for 512 MB | Render builds it (or CI does — [it must, on free](render/README.md#build-oom-javascript-heap-out-of-memory)) | $0, demo-grade, filesystem is wiped by design |
| [`huggingface/`](huggingface/README.md) | `scripts/deploy-hf-space.sh` + the 2 files a Docker Space needs | Space builds it, ~1 min (image mode) | 2 vCPU / 16 GB, but creating a Docker Space needs a paid Hub plan |

## The limits that drive every decision here

Verified against each vendor's own docs on 2026-09-15:

* **Render `plan: free`** — 0.1 CPU, 512 MB RAM, sleeps after 15 idle minutes,
  ~750 instance hours + ~500 build minutes per workspace per month, **no persistent
  disk on free**. Open WebUI's published image (torch + whisper + embeddings, ~1-2 GB)
  is OOM-killed here; the slim image in `render/Dockerfile` boots at **349 MB RSS**, so
  a single user does fit.
* **Hugging Face Spaces** — CPU Basic is 2 vCPU / 16 GB / 50 GB, sleeping after 48 h
  without visitors, and its disk is ephemeral (durability requires a Storage Bucket,
  which is paid). The catch: *"Static Spaces are free for everyone. Gradio and Docker
  Spaces run on compute and require a paid plan to create"* (PRO for personal accounts).
  Free accounts get Static Spaces and up to two ZeroGPU Spaces, and **ZeroGPU is
  Gradio-only** — so it cannot host Open WebUI.
* **Open WebUI itself** — the app needs ~1 GB of RAM to be comfortable, ~2 GB to be
  pleasant, plus whatever an embedded model needs. Community-reported floor is 1-2 GB.

## Pick by what you can actually spend

1. **$0 and it must keep working** → rent no PaaS, take a free-forever VM and run the
   stock image. Oracle Cloud Always Free (4 ARM OCPU / 24 GB, subject to regional
   capacity) or GCP's always-free `e2-micro` (1 GB, add swap) both fit:
   ```bash
   docker run -d --name open-webui --restart always \
     -p 8080:8080 -e OPENAI_API_BASE_URL=https://api.openai.com/v1 \
     -e OPENAI_API_KEY=... -e WEBUI_SECRET_KEY=... \
     -v open-webui:/app/backend/data ghcr.io/open-webui/open-webui:main
   ```
   This is also the only free option where "upload a PDF and chat with it" still works
   the next day.
2. **$0 and a throwaway demo is fine** → [`render/`](render/README.md). Expect cold
   starts measured in minutes and data that evaporates on redeploy; pair it with a free
   external Postgres (`DATABASE_URL`) so the chats survive.
3. **$9/month** → [`huggingface/`](huggingface/README.md): HF PRO unlocks Docker Spaces,
   16 GB RAM, no build-minute quota, git-push deploys. Best effort-to-value ratio here.
4. **$25-35/month** → `plan: 1c-2g` + a 1 GB disk in `render.yaml` and Render's free
   tier limitations are gone.

Provider config is the same in all four: `OPENAI_API_BASE_URL` + `OPENAI_API_KEY`
(OpenAI, OpenRouter, Groq, a vLLM endpoint — anything OpenAI-compatible), with
`ENABLE_OLLAMA_API=false` when there is no Ollama to find.

## What is deliberately not in this PR

No changes to the app, the main `Dockerfile`, or CI that runs on every push; the deploy
files are additive, and the only root-level file is `render.yaml`, which Render reads
by convention. The Space's `README.md` frontmatter is generated at push time by
`scripts/deploy-hf-space.sh` rather than committed into the project README, so
`README.md` still renders as documentation on GitHub.

## Reproducing the measurement

The slim dependency set is the risky part (upstream marks `backend/requirements-min.txt`
as "WIP"), so it was booted rather than assumed:

```bash
python3 -m venv /tmp/venv && . /tmp/venv/bin/activate
pip install -r backend/requirements-min.txt -r deploy/render/requirements-addons.txt
mkdir -p /tmp/build && echo '<html></html>' > /tmp/build/index.html   # frontend stand-in
cd backend && DATA_DIR=/tmp/data WEBUI_SECRET_KEY=x FRONTEND_BUILD_DIR=/tmp/build \
  python -m uvicorn open_webui.main:app --port 8080
curl -s localhost:8080/health          # -> {"status":true}
curl -s localhost:8080/api/config      # -> 200
```

`requirements-addons.txt` is exactly the set of modules that failed to import without
it, found by walking the startup import chain. `render/Dockerfile` re-runs that import
as a build step, so drift in either requirements file breaks a build, not a deploy.
