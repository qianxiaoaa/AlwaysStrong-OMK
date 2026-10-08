#!/usr/bin/env bash
# Cross-compile the AlwaysStrong Ed25519 verifier for all 4 Android ABIs and
# copy the binaries into native/verifier/prebuilt/<abi>/verify_tool so build.sh
# can stage them without a Go toolchain on the build host.
#
# Run this whenever native/verifier/src/ changes. CI also runs it.
#
# Requires: a Go toolchain (1.21+). No cgo and no NDK: the verifier is pure Go,
# so GOOS=linux binaries run unchanged on Android.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/native/verifier/src"
OUT="$ROOT/native/verifier/prebuilt"

command -v go >/dev/null 2>&1 || { echo "go not on PATH" >&2; exit 1; }

# abi:GOARCH[:GOARM]
TARGETS="
arm64-v8a:arm64
armeabi-v7a:arm:7
x86:386
x86_64:amd64
"

echo "==> cross-compiling verify_tool (4 ABIs)"
for t in $TARGETS; do
    abi="${t%%:*}"
    rest="${t#*:}"
    arch="${rest%%:*}"
    arm="${rest#*:}"
    [ "$arm" = "$arch" ] && arm=""

    mkdir -p "$OUT/$abi"
    echo "    $abi (GOARCH=$arch${arm:+ GOARM=$arm})"
    ( cd "$SRC" && \
      env CGO_ENABLED=0 GOOS=linux GOARCH="$arch" ${arm:+GOARM="$arm"} \
      go build -trimpath -ldflags "-s -w" -o "$OUT/$abi/verify_tool" verify_tool.go )
    chmod 0755 "$OUT/$abi/verify_tool"
done

echo "==> done:"
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
    printf '    %-12s %s\n' "$abi" "$(ls -l "$OUT/$abi/verify_tool" | awk '{print $5}') bytes"
done
