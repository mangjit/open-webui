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
# Run:
#   docker run --rm -p 8080:8080 -e OPENAI_API_KEY=... -e WEBUI_SECRET_KEY=... \
#     -v open-webui-slim:/app/backend/data open-webui-slim
# Render (see ./README.md and ../../render.yaml) builds this image for you.

ARG NODE_IMAGE=node:22-alpine3.20
ARG PYTHON_IMAGE=python:3.11-slim-bookworm

######## Frontend ########
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS build
ARG BUILD_HASH=slim-build

WORKDIR /app

# git is only needed so vite can record the revision in the bundle
RUN apk add --no-cache git

# The vite build is the memory-hungry step; cap the heap so it fails with a clear
# JS OOM instead of being kernel-killed, and keep it inside a 4 GB build box.
ENV NODE_OPTIONS=--max-old-space-size=3072 \
    APP_BUILD_HASH=${BUILD_HASH}

COPY package.json package-lock.json ./
RUN npm ci --force --no-audit --no-fund

COPY . .
RUN npm run build

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
COPY --from=build /app/package.json /app/package.json
COPY backend ./

RUN mkdir -p /app/backend/data/cache/tiktoken \
    && chmod -R a+rwX /app/backend/data

# Build-time smoke test: importing open_webui.main walks the whole startup import
# chain, which is exactly where an under-specified dependency set breaks (upstream
# labels requirements-min.txt "WIP"). If this ever fails, the fix is one more line
# in deploy/render/requirements-addons.txt, not a broken deploy 20 minutes later.
#
# Side effect worth knowing about: importing the app runs config.py's branding sync,
# which clears open_webui/static and re-copies it from /app/build/static. That is
# what every container does on first boot anyway, so baking it here is idempotent -
# it just means the image's static dir ends up identical to the frontend build's.
RUN DATA_DIR=/tmp/smoke FRONTEND_BUILD_DIR=/app/build WEBUI_SECRET_KEY=build-check \
        python3 -c "import open_webui.main" \
    && rm -rf /tmp/smoke

EXPOSE 8080

# start-period is generous because Render free takes minutes to boot on 0.1 CPU.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s \
    CMD curl --silent --fail "http://localhost:${PORT:-8080}/health" || exit 1

CMD ["bash", "start.sh"]
