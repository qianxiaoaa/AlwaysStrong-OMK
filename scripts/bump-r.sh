#!/usr/bin/env bash
# Bump AlwaysStrong-OMK's -omk-rN revision by one, refresh versionCode, and
# prepend a changelog section assembled from the upstream-change summary.
#
# Used by .github/workflows/upstream-release.yml after
# scripts/check-payload-upstream.sh found a new OhMyKeymint / PlayIntegrityFork
# release and patched the pins in build.sh.
#
# Reads:   module/module.prop (version, versionCode), build.sh pins,
#          .upstream-changes.txt (optional summary).
# Writes:  module/module.prop (bumped), CHANGELOG.md (new ## section).
# Prints:  the new version tag (e.g. v1.0.5-omk-r2). In CI also appends
#          version / code to $GITHUB_OUTPUT.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROP="$ROOT/module/module.prop"
CHANGELOG="$ROOT/CHANGELOG.md"
SUMMARY="${UPSTREAM_SUMMARY:-$ROOT/.upstream-changes.txt}"

cur_ver=$(sed -n 's/^version=//p' "$PROP" | head -1)     # e.g. v1.0.5-omk-r1
[[ -n "$cur_ver" ]] || { echo "cannot read version from $PROP" >&2; exit 1; }

base="${cur_ver%-omk-r*}"
rev="${cur_ver##*-omk-r}"
if [[ "$base" == "$cur_ver" || ! "$rev" =~ ^[0-9]+$ ]]; then
    echo "unparseable version (want vX.Y.Z-omk-rN): $cur_ver" >&2
    exit 1
fi

ver="${base#v}"
IFS=. read -r MA MI PA <<<"$ver"
if [[ ! "$MA" =~ ^[0-9]+$ || ! "$MI" =~ ^[0-9]+$ || ! "$PA" =~ ^[0-9]+$ ]]; then
    echo "unparseable version: $cur_ver" >&2
    exit 1
fi

new_rev=$((rev + 1))
new_ver="${base}-omk-r${new_rev}"
# versionCode mirrors the module's own scheme: v1.0.4-omk-r11 -> 10411.
new_code=$(( (MA * 100 + MI * 10 + PA) * 100 + new_rev ))

# Notes: the upstream summary lines, then the exact bundled versions.
notes=""
# Normalise summary into a bullet list: drop blank lines, avoid double "- -".
[[ -s "$SUMMARY" ]] && notes=$(sed -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*-[[:space:]]*//' -e 's/^/- /' "$SUMMARY")
[[ -n "$notes" ]] || notes="- Maintenance and upstream refresh."

pin() { sed -n "s/^$1=\"\{0,1\}//p" "$ROOT/build.sh" | head -1 | sed 's/"$//'; }
omk_v=$(pin OMK_TAG)
pif_v=$(pin PIF_TAG)
notes+=$'\n\n'"**Bundled in every build of this release**"
notes+=$'\n'"- Keystore: OhMyKeymint \`${omk_v}\`"
notes+=$'\n'"- Play Integrity: PlayIntegrityFork \`${pif_v}\`"

# Bump module.prop
tmp=$(mktemp)
sed -e "s|^version=.*|version=${new_ver}|" \
    -e "s|^versionCode=.*|versionCode=${new_code}|" "$PROP" > "$tmp"
mv "$tmp" "$PROP"

# Prepend a new "## <ver>" section just before the first existing "## " heading,
# so the changelog's intro paragraph stays on top.
notes_file=$(mktemp)
printf '%s\n' "$notes" > "$notes_file"
tmp=$(mktemp)
awk -v nf="$notes_file" -v ver="$new_ver" '
    !ins && /^## / {
        print "## " ver; print ""
        while ((getline l < nf) > 0) print l
        print ""; close(nf); ins = 1
    }
    { print }
    END {
        if (!ins) {
            print ""; print "## " ver; print ""
            while ((getline l < nf) > 0) print l
            print ""
        }
    }
' "$CHANGELOG" > "$tmp"
mv "$tmp" "$CHANGELOG"

echo "$new_ver"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "version=$new_ver"
        echo "code=$new_code"
    } >> "$GITHUB_OUTPUT"
fi
