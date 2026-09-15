---
title: Open WebUI
emoji: 🐳
colorFrom: purple
colorTo: gray
sdk: docker
app_port: 8080
startup_duration_timeout: 30m
header: mini
short_description: Self-hosted AI platform — chat, RAG, users, tools
tags:
  - open-webui
  - chat
  - llm
  - ui
pinned: false
---

# Open WebUI on Hugging Face Spaces

This Space runs Open WebUI from `ghcr.io/open-webui/open-webui:main`
(the pinned tag is in the `Dockerfile` next to this README).

## Required configuration

Set these in **Space → Settings → Variables and secrets** — never in the repo.
See `deploy/huggingface/space.env.example` in the source repository for the full
annotated list.

| Name | Kind | Why |
| --- | --- | --- |
| `WEBUI_SECRET_KEY` | Secret | Signs session JWTs. Losing it logs every user out. |
| `OPENAI_API_KEY` | Secret | Provider key. |
| `OPENAI_API_BASE_URL` | Variable | Any OpenAI-compatible endpoint. |
| `ENABLE_OLLAMA_API=false` | Variable | Nothing to probe, faster boot. |
| `ENABLE_SIGNUP=false` | Variable | A public Space is a public URL. |
| `ADMIN_USER_EMAIL` / `ADMIN_USER_PASSWORD` | Secret | `backend/start.sh` creates the first admin when `SPACE_ID` is set. |

## Persistence (read this before you rely on data)

A Space's own disk is ephemeral: chats, uploads and vector DB are wiped on every
redeploy, restart or 48 h idle sleep. To keep them, attach a
**Storage Bucket** at mount path `/data` (Settings → Volumes) — the `Dockerfile`
already points `DATA_DIR` there. Note that buckets are a paid feature; without
one, treat this Space as a demo.

## Limits of the free CPU Basic tier

2 vCPU / 16 GB RAM / 50 GB disk, sleeps after 48 h without visitors, ~30-90 s
wake. Creating a Docker (or Gradio) Space currently requires a paid Hub plan
(PRO for personal accounts) — free accounts may only create Static Spaces and up
to two ZeroGPU **Gradio** Spaces, and ZeroGPU is not available to the Docker SDK.
Check <https://huggingface.co/docs/hub/spaces-overview> for the current policy.

## Updating

Push to this Space's git repo (`scripts/deploy-hf-space.sh` in the source repo
regenerates these two files and pushes them), or bump the image tag in the
`Dockerfile` with the web editor. Every push rebuilds and restarts the Space.
