#!/usr/bin/env bash
#
# Deploy (or update) a Hugging Face Space running Open WebUI.
#
#   image mode (default)  push README.md + Dockerfile that FROMs a published tag
#   --from-source         push this repo's tree + the repo Dockerfile (for forks)
#
# Nothing here needs a Hugging Face CLI. Auth is the HF write token in $HF_TOKEN,
# handed to git through a throwaway GIT_ASKPASS helper so the token never appears
# in a URL, in .git/config, or in `ps`.
#
set -euo pipefail

REPO_ROOT=$(git -C "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.." rev-parse --show-toplevel)
SPACE_SRC="$REPO_ROOT/deploy/huggingface/space"

HF_SPACE="${HF_SPACE:-}"
HF_USER="${HF_USER:-oauth}"
HF_TOKEN="${HF_TOKEN:-}"
HF_HOST="${HF_HOST:-huggingface.co}"
IMAGE_TAG=""
MODE="image"
REV="HEAD"
DO_CREATE=0
DRY_RUN=0
NO_PUSH=0
VISIBILITY="public"
TITLE="Open WebUI"

usage() {
	cat <<'USAGE'
usage: deploy-hf-space.sh [options]

  --space <user>/<repo>   Space to deploy into           (or $HF_SPACE)
  --tag <image-tag>       rewrite FROM ghcr.io/open-webui/open-webui:<tag>
  --from-source           build the Space from repo source instead of the image
  --ref <rev>             which revision to ship with --from-source  (default HEAD)
  --create                create the Space first (needs a paid Hub plan for Docker)
  --visibility <v>        public|private|protected for --create   (default public)
  --title <str>           Space title for --create
  --dry-run               print the plan, touch nothing
  --no-push               stage the commit locally, do not push
  -h, --help              this text

Environment: HF_TOKEN (required, write scope), HF_SPACE, HF_USER, HF_HOST,
             HF_ORG (only when the Space belongs to an organization).
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--space) HF_SPACE=${2:?}; shift 2 ;;
		--tag) IMAGE_TAG=${2:?}; shift 2 ;;
		--from-source) MODE=source; shift ;;
		--ref) REV=${2:?}; shift 2 ;;
		--create) DO_CREATE=1; shift ;;
		--visibility) VISIBILITY=${2:?}; shift 2 ;;
		--title) TITLE=${2:?}; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		--no-push) NO_PUSH=1; shift ;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			printf 'unknown argument: %s\n\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
done

[ -n "$HF_SPACE" ] || {
	printf 'error: --space <user>/<repo> (or $HF_SPACE) is required\n' >&2
	exit 2
}
case "$HF_SPACE" in
	*/*) ;;
	*)
		printf 'error: --space must look like user/repo, got "%s"\n' "$HF_SPACE" >&2
		exit 2
		;;
esac
case "$VISIBILITY" in
	public | private | protected) ;;
	*)
		printf 'error: --visibility must be public|private|protected\n' >&2
		exit 2
		;;
esac

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf 'error: %s is required\n' "$1" >&2
		exit 3
	}
}
need_cmd git
need_cmd tar

if [ "$DRY_RUN" != 1 ] && [ -z "$HF_TOKEN" ]; then
	printf 'error: HF_TOKEN is required (https://huggingface.co/settings/tokens, write scope)\n' >&2
	exit 2
fi

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

# ── build the payload ──────────────────────────────────────────────────────────
stage_image_mode() {
	cp "$SPACE_SRC/README.md" "$STAGING/payload/README.md"
	if [ -n "$IMAGE_TAG" ]; then
		sed "s#^FROM ghcr.io/open-webui/open-webui:.*#FROM ghcr.io/open-webui/open-webui:${IMAGE_TAG}#" \
			"$SPACE_SRC/Dockerfile" >"$STAGING/payload/Dockerfile"
	else
		cp "$SPACE_SRC/Dockerfile" "$STAGING/payload/Dockerfile"
	fi
}

# Extract the `---` delimited YAML block Hugging Face reads as Space configuration.
front_matter() {
	awk '
		/^---[[:space:]]*$/ { n++; print; if (n == 2) exit; next }
		n == 1 { print }
	' "$1"
}

stage_source_mode() {
	# `git archive` ships tracked files only: .gitignore'd junk never reaches HF.
	mkdir -p "$STAGING/payload"
	git -C "$REPO_ROOT" archive --format=tar "$REV" | tar -x -C "$STAGING/payload"
	[ -f "$STAGING/payload/Dockerfile" ] || {
		printf 'error: %s has no root Dockerfile; a Docker Space needs one\n' "$REV" >&2
		exit 4
	}
	# HF reads the config from the Space repo's root README, so prepend our front
	# matter to the project README rather than committing deploy config into it.
	{
		front_matter "$SPACE_SRC/README.md"
		printf '\n'
		cat "$STAGING/payload/README.md" 2>/dev/null || true
		printf '\n---\n\n## About this Space\n\nBuilt from `%s` @ `%s` by\n`scripts/deploy-hf-space.sh --from-source`. Re-run that command to update.\n' \
			"$(basename "$REPO_ROOT")" "$(git -C "$REPO_ROOT" rev-parse --short "$REV")"
	} >"$STAGING/payload/README.md.tmp"
	mv "$STAGING/payload/README.md.tmp" "$STAGING/payload/README.md"
}

mkdir -p "$STAGING/payload"
case "$MODE" in
	image) stage_image_mode ;;
	source) stage_source_mode ;;
esac

payload_files=$(find "$STAGING/payload" -type f | wc -l | tr -d ' ')
printf 'mode    : %s\n' "$MODE"
printf 'space   : %s\n' "$HF_SPACE"
printf 'payload : %s file(s), e.g. %s\n' "$payload_files" \
	"$(cd "$STAGING/payload" && find . -type f | sed 's#^\./##' | sort | head -6 | tr '\n' ' ')"
printf 'Dockerfile base: %s\n' "$(grep -m1 '^FROM ' "$STAGING/payload/Dockerfile" || true)"

if [ "$DRY_RUN" = 1 ]; then
	printf '\n--dry-run: nothing created, nothing pushed.\n'
	exit 0
fi

need_cmd curl

# ── optionally create the Space ────────────────────────────────────────────────
if [ "$DO_CREATE" = 1 ]; then
	name=${HF_SPACE##*/}
	body=$(printf '{"name":"%s","type":"space","spaceSdk":"docker","visibility":"%s","title":"%s"' \
		"$name" "$VISIBILITY" "$TITLE")
	# The API needs an explicit organization field for org-owned Spaces; a plain
	# `user/repo` id is enough when the Space belongs to the token's own account.
	if [ -n "${HF_ORG:-}" ]; then
		body="${body},\"organization\":\"${HF_ORG}\""
	fi
	body="${body}}"

	printf '\ncreating Space via the Hub API ...\n'
	http_code=$(curl -s -o "$STAGING/create.json" -w '%{http_code}' \
		-X POST "https://$HF_HOST/api/spaces" \
		-H "Authorization: Bearer $HF_TOKEN" \
		-H 'Content-Type: application/json' \
		--data "$body") || http_code=000
	case "$http_code" in
		2*) printf 'created (HTTP %s)\n' "$http_code" ;;
		*)
			printf 'Hub API returned HTTP %s:\n  %s\n' "$http_code" "$(tr -d '\n' <"$STAGING/create.json")" >&2
			cat >&2 <<HINT

If that error mentions plans or "requires a paid subscription", it is Hugging Face's
policy for compute Spaces (Docker/Gradio), not a problem with this script: free
accounts cannot create them. Either subscribe, push to a Space that already exists,
or see deploy/render/README.md for the $0 options.

You can also create it by hand, then re-run without --create:
  https://$HF_HOST/new-space?sdk=docker&name=$name
HINT
			exit 5
			;;
	esac
fi

# ── push ───────────────────────────────────────────────────────────────────────
cat >"$STAGING/askpass.sh" <<'ASKPASS'
#!/bin/sh
# git asks for a username, then a password; the Hub accepts <user>:<token> basic auth.
case "$1" in
	*sername*) printf '%s\n' "${HF_USER:-oauth}" ;;
	*assword*) printf '%s\n' "$HF_TOKEN" ;;
esac
ASKPASS
chmod 700 "$STAGING/askpass.sh"

export GIT_ASKPASS="$STAGING/askpass.sh"
export GIT_TERMINAL_PROMPT=0
export GIT_LFS_SKIP_SMUDGE=1
export HF_USER HF_TOKEN

SPACE_URL="https://$HF_HOST/spaces/$HF_SPACE"
printf '\ncloning %s\n' "$SPACE_URL"
git clone --quiet "$SPACE_URL" "$STAGING/space" 2>"$STAGING/clone.err" || {
	sed 's/^/  /' "$STAGING/clone.err" >&2
	printf 'error: could not clone the Space repo. Does it exist? Add --create, and check\n' >&2
	printf '       that HF_TOKEN has write access and %s is a Docker Space.\n' "$HF_SPACE" >&2
	exit 6
}

if [ "$MODE" = source ]; then
	# A source deploy replaces the whole tree (keeping the git metadata).
	find "$STAGING/space" -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
fi
cp -a "$STAGING/payload/." "$STAGING/space/"

cd "$STAGING/space"
git config user.name "${GIT_AUTHOR_NAME:-open-webui-deploy}"
git config user.email "${GIT_AUTHOR_EMAIL:-deploy@localhost}"
git add -A
if git diff --cached --quiet; then
	printf '\nSpace is already up to date - nothing to push.\n'
	exit 0
fi

sha=$(git -C "$REPO_ROOT" rev-parse --short "$REV")
subject="deploy open-webui ($MODE, $sha)"
[ -z "$IMAGE_TAG" ] || subject="deploy open-webui (image tag $IMAGE_TAG, $sha)"
git commit -q -m "$subject"

branch=$(git symbolic-ref --quiet --short HEAD || echo main)

if [ "$NO_PUSH" = 1 ]; then
	printf '\n--no-push: committed "%s" locally at %s, not pushed.\n' "$subject" "$PWD"
	exit 0
fi

git push --quiet origin "HEAD:$branch"
printf '\npushed "%s" to %s (branch %s)\n' "$subject" "$HF_SPACE" "$branch"
cat <<DONE

Next:
  1. https://$HF_HOST/spaces/$HF_SPACE/settings/variables
     set what deploy/huggingface/space.env.example lists - at minimum
     WEBUI_SECRET_KEY and OPENAI_API_KEY.
  2. Settings -> Hardware: cpu-basic (2 vCPU / 16 GB) is the free flavor.
  3. Settings -> Volumes: attach a bucket at /data so chats/uploads survive a rebuild.
  4. App: https://$HF_HOST/spaces/$HF_SPACE/ once the build finishes.
DONE
