#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-sxuff/qwen38-27b-stock-dflash2:2026-09-06-nvfp4-draft}"
DOCKER_BUILDKIT=1 docker build -t "$IMAGE" -f "$ROOT/docker/Dockerfile" "$ROOT/docker"
docker image inspect "$IMAGE" --format '{{.Id}} {{json .Config.Labels}}'
