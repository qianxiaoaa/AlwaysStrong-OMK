#!/usr/bin/env bash
# Build and publish the signed component (packages) index.
#
# Runs scripts/gen-packages.py to resolve every component in packages/sources.json
# from upstream GitHub releases, then commits mirror/packages.json and its detached
# signature mirror/packages.json.sig to the `mirror-data` branch that devices fetch.
#
# Usage: publish-packages.sh [owner/repo]
#
# Env:
#   ALWAYSSTRONG_SIGNING_KEY  required. base64(PKCS8 PEM ed25519 private key)
#   GH_TOKEN / GITHUB_TOKEN   required. contents:write on the repo (also used for
#                             GitHub API during resolution)
#   MIRROR_REMOTE             git remote to push mirror-data to (default origin)
#   MIRROR_BRANCH             default mirror-data
#   PKG_ONLY                  optional comma list of component names (debug)
#
# Exit: 0 ok · 2 bad input/tools · 3 mirror-data branch missing · other = failure

set -euo pipefail

REPO="${1:-${GITHUB_REPOSITORY:-}}"
[ -n "$REPO" ] || { echo "repo not given and GITHUB_REPOSITORY unset" >&2; exit 2; }

: "${ALWAYSSTRONG_SIGNING_KEY:?ALWAYSSTRONG_SIGNING_KEY is required}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$TOKEN" ] || { echo "GH_TOKEN/GITHUB_TOKEN is required" >&2; exit 2; }
export GH_TOKEN="$TOKEN"
export GITHUB_TOKEN="$TOKEN"

MIRROR_REMOTE="${MIRROR_REMOTE:-origin}"
MIRROR_BRANCH="${MIRROR_BRANCH:-mirror-data}"

for t in git python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; exit 2; }
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. build + sign the index ---------------------------------------------
args=(--registry packages/sources.json --out "$WORK/packages.json" --repo "$REPO"
      --key-file "$WORK/sign.pem")
printf '%s' "$ALWAYSSTRONG_SIGNING_KEY" | base64 -d > "$WORK/sign.pem"
[ -n "${PKG_ONLY:-}" ] && args+=(--only "$PKG_ONLY")
python3 scripts/gen-packages.py "${args[@]}"
rm -f "$WORK/sign.pem"

# ---- 2. publish to the mirror-data branch ----------------------------------
echo "==> publishing mirror/$MIRROR_BRANCH"
git fetch -q "$MIRROR_REMOTE" "$MIRROR_BRANCH" 2>/dev/null || true
if ! git show-ref --verify --quiet "refs/remotes/$MIRROR_REMOTE/$MIRROR_BRANCH"; then
    echo "branch $MIRROR_BRANCH not found on $MIRROR_REMOTE (create it once, then re-run)" >&2
    exit 3
fi

WT="$WORK/mirror"
git worktree add -q -B "$MIRROR_BRANCH" "$WT" "$MIRROR_REMOTE/$MIRROR_BRANCH"
mkdir -p "$WT/mirror"
cp "$WORK/packages.json" "$WT/mirror/packages.json"
cp "$WORK/packages.json.sig" "$WT/mirror/packages.json.sig"
(
    cd "$WT"
    git add -A
    if git -c user.name="github-actions[bot]" \
           -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
           commit -q -m "packages: refresh component index"; then
        git push -q "$MIRROR_REMOTE" "HEAD:$MIRROR_BRANCH"
    else
        echo "    (no change)"
    fi
)
git worktree remove --force "$WT" 2>/dev/null || true

echo "==> done: $MIRROR_BRANCH/mirror/packages.json"
