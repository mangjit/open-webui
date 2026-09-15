# Deploy this repo to a Hugging Face Space

Two ways in, both driven by `scripts/deploy-hf-space.sh`:

| Mode | What lands in the Space | Build time | Use when |
| --- | --- | --- | --- |
| `image` (default) | `README.md` + a 1-line `Dockerfile` that does `FROM ghcr.io/open-webui/open-webui:<tag>` | ~1 min | you want Open WebUI running, version-pinned, no compile |
| `--from-source` | this repo's tree + the repo `Dockerfile`, with Space frontmatter prepended to `README.md` | 20-40 min | you need **this fork's** code in the container |

The Space needs nothing else from this repo: `git` push the two files, HF builds.

## 0. The gate you have to clear first

Creating a **Docker** (or Gradio) Space requires a **paid Hub plan** — PRO for
personal accounts, Team/Enterprise for orgs. Free accounts may create Static
Spaces and up to two ZeroGPU Spaces, but ZeroGPU is Gradio-only, so it cannot host
Open WebUI. This is HF's current policy
([spaces-overview](https://huggingface.co/docs/hub/spaces-overview)), not a
limitation of these files. Spaces that already existed before the change still
run and can still be pushed to, so an old free Docker Space works fine here.

If PRO is a no, jump to [`../render/README.md`](../render/README.md) or the free
VM options in [`../README.md`](../README.md).

## 1. One-time setup

```bash
# Hub token with write access: https://huggingface.co/settings/tokens
export HF_TOKEN=hf_xxx
export HF_SPACE=<your-username>/open-webui       # the Space repo id
```

## 2. Create the Space (or skip if it already exists)

```bash
scripts/deploy-hf-space.sh --create
```

That calls the Hub API; on a free account the server replies with the paid-plan
error — read it, it's HF telling you the tier situation, not a bug in the script.

## 3. Deploy

```bash
scripts/deploy-hf-space.sh                       # image mode, tag "main"
scripts/deploy-hf-space.sh --tag v0.9.5          # pin a release
scripts/deploy-hf-space.sh --from-source         # build this checkout
scripts/deploy-hf-space.sh --from-source --ref HEAD~3
scripts/deploy-hf-space.sh --dry-run             # show what would be pushed
```

Then set variables/secrets in **Settings → Variables and secrets** — the annotated
list is in [`space.env.example`](space.env.example). Without `WEBUI_SECRET_KEY` the
container regenerates a key on every restart and invalidates all sessions.

## 4. Persistence

A Space's disk is wiped on restart/rebuild/sleep. Attach a **Storage Bucket** at
mount path `/data` (Settings → Volumes); `space/Dockerfile` already sets
`DATA_DIR=/data` so the SQLite DB, uploads and vector store land there. Buckets
are paid — that is the honest price of a durable Space. No bucket ⇒ expect to
re-create your admin account after each rebuild.

## Optional: deploy from CI

`github-action.yaml` in this directory is a ready-made `workflow_dispatch` wrapper
around the same script (it is a template on purpose, so nothing runs on a push until
you copy it into `.github/workflows/`):

```bash
cp deploy/huggingface/github-action.yaml .github/workflows/deploy-huggingface-space.yaml
gh secret set HF_TOKEN          # Hub token, write scope
gh workflow run "Deploy Hugging Face Space" -f space=<user>/<repo> -f mode=image -f image_tag=main
```

## What the script does not do

* It never stores `HF_TOKEN` on disk: git authenticates through a `GIT_ASKPASS`
  helper that reads the variable from the environment.
* It does not delete files in the Space repo that aren't in `image` mode's two
  files, except in `--from-source` mode where the tree replaces the tree.
* It does not touch secrets; HF only exposes secret *names* over the API.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Creating a Space that runs on compute requires a paid plan` | HF policy, see step 0. |
| Build fails: `Dockerfile not found` | Space SDK isn't `docker`; the README frontmatter (`sdk: docker`) must be committed. |
| `app_port` mismatch / 502 | Space expects the port in the frontmatter; we use 8080 and set `PORT=8080`. |
| "Running" but blank page, then rebuild | Startup exceeded the build timeout; raise `startup_duration_timeout` in the Space README frontmatter. |
| Every user logged out after each restart | `WEBUI_SECRET_KEY` unset. |
| Chats gone after a rebuild | No bucket at `/data`, see step 4. |
