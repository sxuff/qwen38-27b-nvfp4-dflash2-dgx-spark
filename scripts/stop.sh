#!/usr/bin/env bash
set -Eeuo pipefail
NAME="${NAME:-qwen38-27b-stock-nvfp4}"
if ! docker inspect "$NAME" >/dev/null 2>&1; then exit 0; fi
owned=$(docker inspect -f '{{index .Config.Labels "io.sxuff.qwen38.recipe"}}' "$NAME" 2>/dev/null || true)
[[ "$owned" == true ]] || { echo "refusing to stop unowned container $NAME" >&2; exit 2; }
docker rm -f "$NAME" >/dev/null
