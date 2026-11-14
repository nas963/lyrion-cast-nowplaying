#!/usr/bin/env bash
# Runs tests/*.t against src/CastNowPlaying (exposed as Plugins::CastNowPlaying).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$(mktemp -d)"
trap 'rm -rf "$LIB"' EXIT
mkdir -p "$LIB/Plugins"
cp -r "$ROOT/src/CastNowPlaying" "$LIB/Plugins/"
for t in "$ROOT"/tests/*.t; do perl -I"$LIB" "$t"; done
