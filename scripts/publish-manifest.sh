#!/usr/bin/env bash
# Build and publish the signed AlwaysStrong update manifest for a release.
#
# Reads the release's module zip, signs it with the Ed25519 key in
# $ALWAYSSTRONG_SIGNING_KEY (base64 of a PKCS8 PEM), writes manifest.json via
# scripts/gen-manifest.py, attaches it to the release, and commits it to the
# `mirror-data` branch (mirror/manifest.json) that devices fetch from.
#
# Usage: publish-manifest.sh <tag> [owner/repo]
#
# Env:
#   ALWAYSSTRONG_SIGNING_KEY  required. base64(PKCS8 PEM ed25519 private key)
#   GH_TOKEN / GITHUB_TOKEN   required. needs contents:write on the repo
#   MIRROR_REMOTE             git remote to push mirror-data to (default origin)
#   MIRROR_BRANCH             default mirror-data
#
# Exit: 0 ok · 2 bad input/tools · 3 mirror-data branch missing · other = failure

set -euo pipefail

TAG="${1:-}"
REPO="${2:-${GITHUB_REPOSITORY:-}}"
[ -n "$TAG" ]  || { echo "usage: publish-manifest.sh <tag> [owner/repo]" >&2; exit 2; }
[ -n "$REPO" ] || { echo "repo not given and GITHUB_REPOSITORY unset" >&2; exit 2; }

: "${ALWAYSSTRONG_SIGNING_KEY:?ALWAYSSTRONG_SIGNING_KEY is required}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$TOKEN" ] || { echo "GH_TOKEN/GITHUB_TOKEN is required" >&2; exit 2; }
export GH_TOKEN="$TOKEN"

MIRROR_REMOTE="${MIRROR_REMOTE:-origin}"
MIRROR_BRANCH="${MIRROR_BRANCH:-mirror-data}"

for t in gh openssl python3 git; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; exit 2; }
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. release zip ---------------------------------------------------------
echo "==> downloading $TAG asset from $REPO"
gh release download "$TAG" -R "$REPO" -p '*.zip' -D "$WORK" --clobber
ZIP="$(ls "$WORK"/*.zip | head -n1)"
[ -f "$ZIP" ] || { echo "no zip asset found for $TAG" >&2; exit 2; }
echo "    $ZIP ($(wc -c < "$ZIP") bytes)"

# ---- 2. sign ----------------------------------------------------------------
printf '%s' "$ALWAYSSTRONG_SIGNING_KEY" | base64 -d > "$WORK/sign.pem"
SIG_RAW="$WORK/module.sig"
SIG_B64="$WORK/module.sig.b64"
openssl pkeyutl -sign -inkey "$WORK/sign.pem" -rawin -in "$ZIP" -out "$SIG_RAW"
base64 -w0 "$SIG_RAW" > "$SIG_B64"
rm -f "$WORK/sign.pem"

# ---- 3. manifest ------------------------------------------------------------
PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 scripts/gen-manifest.py \
    --zip "$ZIP" --sig-file "$SIG_B64" --out "$WORK/manifest.json" \
    --repo "$REPO" --tag "$TAG" --published-at "$PUBLISHED_AT"

# ---- 4. attach to the release ----------------------------------------------
echo "==> attaching manifest.json to $TAG"
gh release upload "$TAG" "$WORK/manifest.json" -R "$REPO" --clobber

# ---- 5. publish to the mirror-data branch ----------------------------------
echo "==> publishing mirror/$MIRROR_BRANCH"
git fetch -q "$MIRROR_REMOTE" "$MIRROR_BRANCH" 2>/dev/null || true
if ! git show-ref --verify --quiet "refs/remotes/$MIRROR_REMOTE/$MIRROR_BRANCH"; then
    echo "branch $MIRROR_BRANCH not found on $MIRROR_REMOTE (create it once, then re-run)" >&2
    exit 3
fi

WT="$WORK/mirror"
git worktree add -q -B "$MIRROR_BRANCH" "$WT" "$MIRROR_REMOTE/$MIRROR_BRANCH"
mkdir -p "$WT/mirror"
cp "$WORK/manifest.json" "$WT/mirror/manifest.json"
(
    cd "$WT"
    git add -A
    git -c user.name="github-actions[bot]" \
        -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit -q -m "manifest: $TAG" || echo "    (no change)"
    git push -q "$MIRROR_REMOTE" "HEAD:$MIRROR_BRANCH"
)
git worktree remove --force "$WT" 2>/dev/null || true

echo "==> done: $TAG"
