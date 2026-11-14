#!/usr/bin/env bash
# Copies src/CastNowPlaying into the live Lyrion Plugins folder on the dev server (no sudo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST=/var/lib/squeezeboxserver/Plugins/CastNowPlaying
# the folder itself is created once with sudo (owner ns); only its contents are replaced here
ssh -o BatchMode=yes lyrion "test -w '$DEST' || { echo 'run once: sudo install -d -o ns -g nogroup -m 755 $DEST' >&2; exit 1; }; rm -rf '$DEST'/*"
scp -q -r "$ROOT"/src/CastNowPlaying/. "lyrion:$DEST/"
echo "deploy ok: $DEST"
