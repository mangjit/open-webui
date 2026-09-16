# syntax=docker/dockerfile:1
#
# Slim Open WebUI image for tiny instances (Render free: 0.1 CPU / 512 MB).
#
# Differences from the repo's main ./Dockerfile, all of them memory-driven:
#   * backend/requirements-min.txt + deploy/render/requirements-addons.txt instead
#     of backend/requirements.txt
#   * no torch / torchvision / sentence-transformers / faster-whisper, so no model
#     download layers at build time (that alone is ~3 GB of image and ~700 MB RSS)
#   * no CUDA, no bundled Ollama, no Playwright
# Consequence: everything that needs a local model (RAG embeddings, local Whisper
# STT, TTS via transformers, image generation with local models) is unavailable.
# Chat over an OpenAI-compatible API, users, models presets, tools/actions,
# notes, and the rest of the app work normally.
#
# Build:
#   docker build -f deploy/render/Dockerfile -t open-webui-slim .
#   # on a small builder, keep sourcemaps off (default) and raise the heap:
#   docker build -f deploy/render/Dockerfile \
#     --build-arg NODE_MAX_OLD_SPACE_SIZE=12288 -t open-webui-slim .
#   # or let CI build it: ./build-image.yaml
# Run:
#   docker run --rm -p 8080:8080 -e OPENAI_API_KEY=... -e WEBUI_SECRET_KEY=... \
#     -v open-webui-slim:/app/backend/data open-webui-slim
# Render (see ./README.md and ../../render.yaml) builds this image for you.

# Frontend build memory. `vite.config.ts` ships with `sourcemap: true`, and the
# SvelteKit rollup graph is big enough that upstream's own release workflow forces
# `--max-old-space-size=12288` on a 16 GB GitHub runner (see
# .github/workflows/docker.yaml, "Prepare CI Dockerfile"). Two knobs here let a
# smaller builder succeed instead: a tunable heap, and dropping sourcemaps, which
# is most of the peak allocation for a build nobody will debug in the browser.
#
# The cap is a ceiling, not an allocation, so a generous default costs nothing on a
# big builder; 8192 matches upstream's pip path and 12288 matches its CI one. If
# `npm run build` still dies with "Reached heap limit ... JavaScript heap out of
# memory", the builder is too small - no build-arg fixes that. Build in CI
# (./build-image.yaml) and let Render pull the image; deploy/render/README.md.
ARG NODE_IMAGE=node:22-alpine3.20
ARG PYTHON_IMAGE=python:3.11-slim-bookworm
ARG NODE_MAX_OLD_SPACE_SIZE=8192
ARG SOURCEMAP=off

######## Frontend ########
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS build
ARG BUILD_HASH=slim-build
ARG NODE_MAX_OLD_SPACE_SIZE
ARG SOURCEMAP

WORKDIR /app

# git is only needed so vite can record the revision in the bundle
RUN apk add --no-cache git

ENV NODE_OPTIONS=--max-old-space-size=${NODE_MAX_OLD_SPACE_SIZE} \
    APP_BUILD_HASH=${BUILD_HASH}

COPY package.json package-lock.json ./
RUN npm ci --force --no-audit --no-fund

COPY . .

# Patched in-image rather than in the repo: the frontend build is the deploy
# target's problem, and vite.config.ts must stay untouched for everyone else.
RUN if [ "${SOURCEMAP}" = "off" ]; then \
        sed -i 's/sourcemap: true/sourcemap: false/' vite.config.ts; \
    fi \
    && npm run build

######## Backend + runtime ########
FROM ${PYTHON_IMAGE} AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    ENV=prod \
    HOST=0.0.0.0 \
    PORT=8080 \
    DATA_DIR=/app/backend/data

## Provider defaults; override at runtime, never bake real keys in.
ENV OLLAMA_BASE_URL="" \
    OPENAI_API_BASE_URL="" \
    OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    ENABLE_OLLAMA_API="false" \
    ANONYMIZED_TELEMETRY="false" \
    SCARF_NO_ANALYTICS="true" \
    DO_NOT_TRACK="true"

## Keep every optional local model disabled so nothing tries to import torch.
ENV RAG_EMBEDDING_MODEL="" \
    RAG_RERANKING_MODEL="" \
    AUXILIARY_EMBEDDING_MODEL="" \
    WHISPER_MODEL="" \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR=/app/backend/data/cache/tiktoken \
    WEB_LOADER_ENGINE="" \
    AUDIO_STT_ENGINE="" \
    AUDIO_TTS_ENGINE="" \
    IMAGE_GENERATION_ENGINE="" \
    ENABLE_WEBSOCKET_SUPPORT="true"

WORKDIR /app/backend

# curl for HEALTHCHECK, git/ffmpeg kept out on purpose (image size).
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Silence chromadb's telemetry (mirrors the main Dockerfile)
RUN mkdir -p /root/.cache/chroma \
    && echo -n 00000000-0000-0000-0000-000000000000 > /root/.cache/chroma/telemetry_user_id

COPY backend/requirements-min.txt /tmp/requirements-min.txt
COPY deploy/render/requirements-addons.txt /tmp/requirements-addons.txt

# uv resolves this set in seconds versus minutes with plain pip (same as upstream).
RUN pip3 install --no-cache-dir uv \
    && uv pip install --system --no-cache-dir \
        -r /tmp/requirements-min.txt \
        -r /tmp/requirements-addons.txt \
    && rm -f /tmp/requirements-min.txt /tmp/requirements-addons.txt

COPY --from=build /app/build /app/build
COPY --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --from=build /app/package.json /app/package.json
COPY backend ./

RUN mkdir -p /app/backend/data/cache/tiktoken \
    && chmod -R a+rwX /app/backend/data

# Optional guard: importing open_webui.main walks the whole startup import chain,
# which is where an under-specified dependency set breaks (upstream marks
# requirements-min.txt "WIP"; this image swaps in requirements-min + addons).
#
# Warn-only by default, deliberately. Two earlier revisions of this layer failed
# the build while hiding the reason (first an uncreated DATA_DIR, then a shell
# dance whose exit code outran the traceback), and a guard that costs a 20-minute
# build cycle to be wrong is worse than no guard. Keep it fatal in CI, where the
# traceback is easy to read and a green build is cheap to redo:
#     docker build --build-arg SMOKE_STRICT=true ...
# If it warns here, the container will almost certainly crash on the same import at
# boot - Render's *runtime* log is complete, so that is the faster thing to read.
#
# DATA_DIR must exist before the import: env.py only creates it on the pip-install
# path (FROM_INIT_PY), not in this /app/backend layout.
ARG SMOKE_STRICT=false
RUN mkdir -p /tmp/.smoke/data \
    && { DATA_DIR=/tmp/.smoke/data FRONTEND_BUILD_DIR=/app/build WEBUI_SECRET_KEY=build-check \
           python3 -c "import open_webui.main" \
         && echo 'slim-image smoke test: import OK' \
         || { echo 'WARNING: slim-image smoke test failed (traceback above). Fix by adding the missing module to deploy/render/requirements-addons.txt, pinned to its version in backend/requirements.txt.'; \
              if [ "${SMOKE_STRICT}" = "true" ]; then exit 1; fi; }; } \
    && rm -rf /tmp/.smoke

EXPOSE 8080

# start-period is generous because Render free takes minutes to boot on 0.1 CPU.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s \
    CMD curl --silent --fail "http://localhost:${PORT:-8080}/health" || exit 1

CMD ["bash", "start.sh"]
