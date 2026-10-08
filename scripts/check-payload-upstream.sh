#!/usr/bin/env bash
# Check the two release payloads AlwaysStrong-OMK pins in build.sh — the
# OhMyKeymint engine (ITxiao6666 fork) and PlayIntegrityFork (osm0sis) — against
# their newest GitHub releases, and optionally bump the pins.
#
# This is this repo's counterpart to upstream AlwaysStrong's
# scripts/update-upstream.sh: same shape (report newer tags, patch the pins,
# leave a summary for the release bumper), narrowed to the one engine and the
# one PIF pin this module actually builds from.
#
# Usage:
#   scripts/check-payload-upstream.sh            # dry-run, report what is newer
#   scripts/check-payload-upstream.sh --apply    # bump the pins in build.sh
#
# Set GH_TOKEN (or GITHUB_TOKEN) to authenticate the API calls; unauthenticated
# CI runners share a 60 req/h pool per IP and hit the limit.
#
# Exit codes:
#   0  nothing to update
#   10 updates available (dry-run only)
#   11 updates applied
#   1  error (a payload lookup failed)
set -euo pipefail

APPLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_SH="$ROOT/build.sh"
SUMMARY="${UPSTREAM_SUMMARY:-$ROOT/.upstream-changes.txt}"
[[ $APPLY -eq 1 ]] && : > "$SUMMARY"
note() { [[ $APPLY -eq 1 ]] && printf '%s\n' "$1" >> "$SUMMARY" || true; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need curl
if command -v python3 >/dev/null 2>&1; then PY=python3
elif command -v python >/dev/null 2>&1; then PY=python
else echo "missing: python3" >&2; exit 1; fi

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
CURL_AUTH=()
[[ -n "$TOKEN" ]] && CURL_AUTH=(-H "Authorization: Bearer $TOKEN")

# api_latest REPO FILTER — newest non-draft release (prereleases included) that
# carries a .zip asset containing FILTER. Prints tag, asset name, and kind.
api_latest() {
    local repo="$1" prefer="$2"
    curl -sSL --retry 2 --max-time 30 "${CURL_AUTH[@]}" \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${repo}/releases?per_page=20" \
    | "$PY" -c "
import json, sys
raw = json.load(sys.stdin)
if isinstance(raw, dict):                       # rate limit / 404 -> {'message': ...}
    sys.exit('github api: ' + raw.get('message', 'unexpected response'))
prefer = '$prefer'
rels = [r for r in raw if not r.get('draft')]
def asset(r):
    # newest upload first, so a re-cut asset within one tag wins over API order
    a = sorted((x for x in r.get('assets', []) if x['name'].endswith('.zip')),
               key=lambda x: x.get('created_at', ''), reverse=True)
    n = [x['name'] for x in a]
    m = [x for x in n if not prefer or prefer in x]
    return m[0] if m else None
rels = [(r, asset(r)) for r in rels]
rels = [(r, a) for r, a in rels if a]
if not rels:
    sys.exit('no release with a matching .zip asset in ${repo}')
r, a = max(rels, key=lambda t: t[0]['published_at'])
print(r['tag_name']); print(a)
print('prerelease' if r.get('prerelease') else 'stable')
" | tr -d '\r'
}

# read_kv FILE KEY — the quoted value of a KEY="..." assignment
read_kv() { sed -n "s/^$2=\"\{0,1\}//p" "$1" | head -1 | sed 's/"$//'; }

# patch_kv FILE KEY VALUE
patch_kv() {
    local file="$1" key="$2" val="${3//$'\r'/}"
    grep -qE "^${key}=" "$file" || return 0
    sed -i.bak "s|^${key}=.*|${key}=\"${val}\"|" "$file" && rm -f "$file.bak"
}

# not_a_downgrade CUR NEW — false only when NEW sorts strictly below CUR.
not_a_downgrade() {
    [ "$1" = "$2" ] && return 0
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]
}

CHANGED=0
FAILED=0

# check_pin LABEL REPO FILTER TAG_KEY ASSET_KEY
check_pin() {
    local label="$1" repo="$2" filter="$3" tag_key="$4" asset_key="$5"
    local out tag_new asset_new kind tag_cur asset_cur
    if ! out=$(api_latest "$repo" "$filter"); then
        echo "    $label lookup failed ($repo)" >&2
        FAILED=1
        return 0
    fi
    tag_new=$(sed -n 1p <<<"$out")
    asset_new=$(sed -n 2p <<<"$out")
    kind=$(sed -n 3p <<<"$out")
    tag_cur=$(read_kv "$BUILD_SH" "$tag_key")
    asset_cur=$(read_kv "$BUILD_SH" "$asset_key")

    if [[ "$tag_cur" == "$tag_new" && "$asset_cur" == "$asset_new" ]]; then
        printf '    %-5s %s (up to date, %s)\n' "$label" "$tag_cur" "$kind"
    elif ! not_a_downgrade "$tag_cur" "$tag_new"; then
        printf '    %-5s refusing downgrade %s  ->  %s (kept)\n' "$label" "$tag_cur" "$tag_new" >&2
    else
        printf '    %-5s %s  ->  %s   (%s, %s)\n' "$label" "$tag_cur" "$tag_new" "$asset_new" "$kind"
        CHANGED=1
        if [[ $APPLY -eq 1 ]]; then
            patch_kv "$BUILD_SH" "$tag_key"   "$tag_new"
            patch_kv "$BUILD_SH" "$asset_key" "$asset_new"
            note "Updated $label to $tag_new ($asset_new)."
        fi
    fi
}

echo '==> Querying upstream GitHub releases'
check_pin OMK "ITxiao6666/OhMyKeymint"    "release"         OMK_TAG OMK_ASSET
check_pin PIF "osm0sis/PlayIntegrityFork" "PlayIntegrityFork" PIF_TAG PIF_ASSET

[[ $FAILED -eq 1 ]] && exit 1

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "changed=$([[ $CHANGED -eq 1 ]] && echo true || echo false)" >> "$GITHUB_OUTPUT"
fi

if [[ $CHANGED -eq 0 ]]; then
    echo '==> Up to date.'
    exit 0
fi

if [[ $APPLY -eq 0 ]]; then
    echo '==> Updates available. Re-run with --apply to bump the pins.'
    exit 10
fi

echo '==> Patched.'
exit 11
