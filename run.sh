#!/usr/bin/env bash
# run.sh - one-command setup and launch for this recipe on one NVIDIA GB10.
#
#   git clone https://github.com/sxuff/qwen38-27b-nvfp4-dflash2-dgx-spark && cd qwen38-27b-nvfp4-dflash2-dgx-spark && ./run.sh
#
# Every pin and flag below is copied from this repo's README, manifests or
# receipts; the comment next to each value names its source. Nothing here
# tunes, "improves" or changes a measured setting.
set -euo pipefail
cd "$(dirname "$0")"
REPO_DIR="$(pwd)"

# ===================== recipe config (per repo) =============================
RECIPE_NAME="qwen38-27b-nvfp4-dflash2-dgx-spark"
PORT="${PORT:-8001}"                             # scripts/serve.sh:13 (PORT default)
MODELS_DIR="${MODELS_DIR:-$HOME/models}"         # README.md:61-62 download destinations live under $HOME/models
SRC_DIR="${SRC_DIR:-$HOME/src}"                  # unused: the engine is a Docker image, not a source build
STATE_DIR="${STATE_DIR:-$HOME/.local/state/qwen38-27b-nvfp4-dflash2-dgx-spark}"
NEEDS_TOOLS="git curl sha256sum docker python3"  # scripts/serve.sh + scripts/download.py requirements
NEED_MEM_BYTES=16106127360                       # protocol.json:5 acceptance.minimum_mem_available_bytes
ENGINE_DISK_BYTES=0                              # repo states no image size; scripts/download.py keeps its own 20 GiB free-disk reserve (scripts/download.py:26)
ENGINE_KIND=docker
CONTAINER_NAME="qwen38-27b-stock-nvfp4"          # scripts/serve.sh:11 (NAME default)
READY_URL="http://127.0.0.1:${PORT}/v1/models"   # readiness endpoint polled by scripts/run_study.sh:26
READY_TIMEOUT=1200                               # scripts/run_study.sh:24 readiness deadline
EXPECTED_LINE="71.50 tok/s (median whole-request completion rate, single stream, prefill included; Maurienne NVFP4 drafter, D=16; README.md:11)"
RECEIPT_PATH="evidence/recipe-refresh-gb10.json"

# Pinned engine: a Docker image rebuilt from this repo's docker/Dockerfile on a
# digest-pinned base.
BASE_IMAGE="lmsysorg/sglang@sha256:febfb971c7352570fc445c466ebd6ffc9d896024958e544a60f2137fd85856b1"  # docker/Dockerfile:1
RUN_IMAGE="${RUN_IMAGE:-sxuff/qwen38-27b-stock-dflash2:run-sh-febfb971c735}"  # run.sh-specific tag (repo tag family: scripts/build_image.sh:4); suffix = first 12 hex of the base digest
# NOTE on image identity: the measured runs are pinned to LOCAL Docker image IDs
# (deployment-manifest.json:4, runtime-manifest.json:6). A rebuild can never
# reproduce a local image ID, so - per the repo owner's decision - this run.sh
# rebuilds docker/Dockerfile on the pinned base digest, verifies the six overlay
# files against runtime-manifest.json, and skips ONLY serve.sh's image-ID
# equality check (scripts/serve.sh:33-35). Every other serve.sh verification and
# every docker/sglang argument below is reproduced verbatim.

# Pinned weights, downloaded and SHA-256-verified by the repo's own downloader
# (scripts/download.py:33-37) against manifests/.
MODEL_DIR="${MODEL_DIR:-$MODELS_DIR/Qwen3.8-27B-NVFP4-52d1adc5f38a}"  # README.md:61; manifests/target.json:114-118 (RadixArk/Qwen3.8-27B-NVFP4 @ 52d1adc5f38aa5ebf099c29ed7025ba34cfbb854, 21,945,295,073 bytes, 22 files)
DRAFT_DIR="${DRAFT_DIR:-$MODELS_DIR/Qwen3.8-27B-DFlash2-NVFP4-RTNcal-bd7a934213c4}"  # README.md:62; manifests/draft-candidate.json:4-5,16 (maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal @ bd7a934213c47a9e7ef69eef36bb3325f47fd1f1, 1,550,171,194 bytes)

# Disk: the weights are fetched by the repo's own scripts/download.py, which the shared disk step
# does not see. Count the remaining weight bytes and the base image here so --check reports a shortfall.
_present() { if [ -e "$1" ]; then du -sb "$1" 2>/dev/null | cut -f1; else echo 0; fi; }
_want=23495466267   # manifests/target.json:114-118 + manifests/draft-candidate.json:16
_have=$(( $(_present "$MODEL_DIR") + $(_present "$DRAFT_DIR") ))
ENGINE_DISK_BYTES=$(( _want > _have ? _want - _have : 0 ))
ENGINE_DISK_BYTES=$(( ENGINE_DISK_BYTES + 21474836480 ))   # + the free-disk reserve scripts/download.py keeps (its --reserve-gib default, 20 GiB)
# Base image 38,619,182,431 bytes (qwen38-27b-fp8-gx10 runtime-manifest.json:8 records it for this same digest); not counted once pulled.
docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || ENGINE_DISK_BYTES=$(( ENGINE_DISK_BYTES + 38619182431 ))

WEIGHTS="
"

overlay_ok() {   # verify the 6 SGLang overlay files against runtime-manifest.json:8-39 (read-only)
  python3 - <<'PY'
import hashlib, json
from pathlib import Path
manifest = json.loads(Path('runtime-manifest.json').read_text())
bad = []
for row in manifest['overlay_files']:
    data = (Path('docker') / row['path']).read_bytes()
    if len(data) != row['bytes'] or hashlib.sha256(data).hexdigest() != row['sha256']:
        bad.append(row['path'])
if bad:
    raise SystemExit('overlay file mismatch vs runtime-manifest.json: ' + ', '.join(bad))
PY
}

engine_step() {
  image_pin "$BASE_IMAGE"                                                  # docker/Dockerfile:1, by digest
  overlay_ok && ok "overlay files match runtime-manifest.json sha256s"
  if docker image inspect "$RUN_IMAGE" >/dev/null 2>&1; then ok "image present: $RUN_IMAGE"
  else doit env IMAGE="$RUN_IMAGE" "$REPO_DIR/scripts/build_image.sh"; fi  # scripts/build_image.sh:4-5
}

weights_step() { # repo downloader: pinned revision, resume, per-file SHA-256 (scripts/download.py)
  local role dest mark
  for role in target draft-candidate; do                                   # README.md:61-62; rollback draft intentionally not downloaded
    case "$role" in
      target)          dest="$MODEL_DIR" ;;
      draft-candidate) dest="$DRAFT_DIR" ;;
    esac
    mark="$STATE_DIR/weights-ok-$role"
    if [ -f "$mark" ] && [ -d "$dest" ]; then ok "verified earlier: $role -> $dest"; continue; fi
    if [ "$CHECK" = 1 ]; then plan "python3 scripts/download.py $role --destination $dest  (pinned revision + per-file SHA-256)"; continue; fi
    mkdir -p "$STATE_DIR"
    python3 "$REPO_DIR/scripts/download.py" "$role" --destination "$dest"  # README.md:61-62
    date -u +%FT%TZ > "$mark"; ok "downloaded + sha256-verified: $role -> $dest"
  done
}

serve_step() {
  if [ "$CHECK" = 1 ]; then
    plan "verify sealed contract + target/draft files (scripts/verify_contract.py, scripts/verify_artifacts.py; serve.sh:27-31)"
    plan "docker create $CONTAINER_NAME from $RUN_IMAGE with the scripts/serve.sh:42,55,57 argument list and start it"
    return
  fi
  python3 "$REPO_DIR/scripts/verify_contract.py" >/dev/null                # scripts/serve.sh:27
  python3 "$REPO_DIR/scripts/verify_artifacts.py" --manifest "$REPO_DIR/manifests/target.json" --root "$MODEL_DIR" --report "$STATE_DIR/target-verification.json" >/dev/null           # scripts/serve.sh:28
  python3 "$REPO_DIR/scripts/verify_artifacts.py" --manifest "$REPO_DIR/manifests/draft-candidate.json" --root "$DRAFT_DIR" --report "$STATE_DIR/draft-verification.json" >/dev/null   # scripts/serve.sh:19,31
  NAME="$CONTAINER_NAME" "$REPO_DIR/scripts/stop.sh"                       # remove a stale recipe-owned container (scripts/serve.sh:37-41)
  # The image-ID equality check of scripts/serve.sh:33-35 is intentionally skipped
  # here because $RUN_IMAGE is a rebuild (see NOTE above). Everything below is
  # scripts/serve.sh verbatim: docker flags from serve.sh:57; server args from
  # serve.sh:42 and serve.sh:55 with the script's own defaults - MODE=dflash2
  # (serve.sh:4), DRAFT_VARIANT=candidate -> modelopt_fp4 + DRAFT_TOKENS=16
  # (serve.sh:19,23), SERVER_RANDOM_SEED=17 (serve.sh:9), MEM_FRACTION_STATIC=0.70
  # (serve.sh:14), CPUSET=5-9,15-19 (serve.sh:15); draft mounted at /draft
  # (serve.sh:52-53).
  local id
  id=$(docker create --name "$CONTAINER_NAME" --gpus all --ipc host --network host \
    --cpuset-cpus 5-9,15-19 --memory 110g --memory-swap 110g \
    --label io.sxuff.qwen38.recipe=true --label io.sxuff.qwen38.mode=dflash2 \
    --label io.sxuff.qwen38.draft_variant=candidate \
    -v "$MODEL_DIR:/model:ro" -v "$DRAFT_DIR:/draft:ro" \
    "$RUN_IMAGE" \
    python3 -m sglang.launch_server --trust-remote-code --model-path /model \
    --served-model-name qwen38-27b-stock-nvfp4 --mem-fraction-static 0.70 \
    --attention-backend flashinfer --chunked-prefill-size 8192 --disable-prefill-cuda-graph \
    --kv-cache-dtype fp8_e4m3 --mamba-ssm-dtype bfloat16 --mamba-full-memory-ratio 4.21 \
    --mamba-radix-cache-strategy extra_buffer --max-mamba-cache-size 50 \
    --max-running-requests 10 --context-length 262144 --random-seed 17 \
    --reasoning-parser qwen3 --tool-call-parser qwen3_coder --sampling-defaults model \
    --enable-metrics --enable-cache-report --host 127.0.0.1 --port "$PORT")
  docker start "$id" >/dev/null
  ok "started $CONTAINER_NAME (follow logs: docker logs -f $CONTAINER_NAME)"
}

stop_override() {  # the repo's own ownership-checked stopper
  doit env NAME="$CONTAINER_NAME" "$REPO_DIR/scripts/stop.sh"              # scripts/stop.sh:3-7
  ok "stopped (or nothing to stop)"
}

curl_test() {      # model name: scripts/serve.sh:42; request fields: protocol.json:46-57
  cat <<EOF
curl -s http://127.0.0.1:${PORT}/v1/chat/completions -H 'Content-Type: application/json' \\
  -d '{"model":"qwen38-27b-stock-nvfp4","messages":[{"role":"user","content":"What is 17*23?"}],"max_tokens":256,"temperature":0,"top_p":1,"seed":17}'
EOF
}
# ===================== end of recipe config =================================

# ---------------------------------------------------------------------------
# Shared machinery (identical in every sxuff recipe repo).
# ---------------------------------------------------------------------------
CHECK=0; ACTION=run
usage() {
  cat <<EOF
Usage: ./run.sh [--check] [--stop] [--help]

Sets up and launches ${RECIPE_NAME} on one NVIDIA GB10 (SM121).

  (no flag)  check the machine, build or pull the pinned engine, download the
             pinned weights, verify SHA-256, start the server, print a test.
             Safe to re-run: finished steps are skipped.
  --check    print what would happen; change nothing.
  --stop     stop the server this script started.
  --help     show this text.

Environment:
  HF_TOKEN     Hugging Face token, read from the environment only, never saved.
  MODELS_DIR   weights        (default: ${MODELS_DIR})
  SRC_DIR      engine source  (default: ${SRC_DIR})
  STATE_DIR    pid and log    (default: ${STATE_DIR})
  PORT         server port    (default: ${PORT})

Expected: ${EXPECTED_LINE}
Receipt:  ${RECEIPT_PATH}
EOF
}
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --stop)  ACTION=stop ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $a (see ./run.sh --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok    %s\n' "$*"; }
plan() { printf '    would %s\n' "$*"; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }
CHECK_FAILED=0   # under --check, a failed pre-flight check is reported and the plan continues
fail() { if [ "$CHECK" = 1 ]; then printf '    FAIL  %s\n' "$*"; CHECK_FAILED=1; else die "$*"; fi; }
human(){ numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
doit() { if [ "$CHECK" = 1 ]; then plan "$*"; else "$@"; fi; }   # mutate, or describe under --check

PIDFILE="${STATE_DIR}/server.pid"
LOGFILE="${STATE_DIR}/server.log"
STOP_CMD="cd ${REPO_DIR} && ./run.sh --stop"

server_running() {
  if [ "$ENGINE_KIND" = docker ]; then
    [ -n "$(docker ps -q --filter "name=^${CONTAINER_NAME}\$" 2>/dev/null)" ]
  else
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
  fi
}

stop_step() {   # may be overridden in the config block (e.g. to call scripts/stop.sh)
  if ! server_running; then ok "nothing started by this script is running"; return; fi
  if [ "$ENGINE_KIND" = docker ]; then doit docker stop "$CONTAINER_NAME"
  else
    local pid; pid="$(cat "$PIDFILE")"; doit kill "$pid"
    if [ "$CHECK" = 0 ]; then
      for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid"; rm -f "$PIDFILE"
    fi
  fi
  ok "stopped"
}
declare -f stop_override >/dev/null && stop_step() { stop_override; }

if [ "$ACTION" = stop ]; then say "Stopping ${RECIPE_NAME}"; stop_step; exit 0; fi
[ "$CHECK" = 1 ] && say "--check: nothing will be changed"

# git checkout of an exact commit, idempotent. Usage: git_pin <url> <sha> <dir>
git_pin() {
  local url="$1" sha="$2" dir="$3"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ]; then ok "source at ${sha:0:12}: $dir"; return; fi
  if [ ! -d "$dir/.git" ]; then doit git clone --quiet "$url" "$dir"; fi
  if [ "$CHECK" = 1 ]; then plan "check out $sha in $dir"; return; fi
  [ -z "$(git -C "$dir" status --porcelain)" ] || die "$dir has local changes; refusing to move it to $sha"
  git -C "$dir" fetch --quiet origin "$sha" 2>/dev/null || git -C "$dir" fetch --quiet origin
  git -C "$dir" checkout --quiet --detach "$sha"
  [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ] || die "could not check out $sha in $dir"
  ok "source at ${sha:0:12}: $dir"
}

# docker image by digest, idempotent. Usage: image_pin <repo@sha256:...>
image_pin() {
  if docker image inspect "$1" >/dev/null 2>&1; then ok "image present: $1"; else doit docker pull "$1"; fi
}

# --- 1. machine ------------------------------------------------------------
say "Machine"
[ "$(uname -m)" = aarch64 ] || die "expected aarch64 (GB10), got $(uname -m)"
command -v nvidia-smi >/dev/null || die "nvidia-smi not found"
GPU="$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader | head -1)"
case "$GPU" in *GB10*", 12.1") ok "GPU: $GPU" ;; *) die "measured on an NVIDIA GB10 (SM121); found: ${GPU:-none}" ;; esac
MISSING=""; for t in $NEEDS_TOOLS; do command -v "$t" >/dev/null || MISSING="$MISSING $t"; done
if [ -n "$MISSING" ]; then fail "missing tool(s):$MISSING"; else ok "tools: $NEEDS_TOOLS"; fi
ALREADY=0; server_running && ALREADY=1
MEM_AVAIL=$(( $(awk '/MemAvailable/ {print $2}' /proc/meminfo) * 1024 ))
if [ "$ALREADY" = 1 ]; then ok "server already running; memory check skipped"
elif [ "$MEM_AVAIL" -lt "$NEED_MEM_BYTES" ]; then
  fail "need $(human "$NEED_MEM_BYTES") available memory, have $(human "$MEM_AVAIL"). Stop other models first (nvidia-smi, docker ps)."
else ok "memory: $(human "$MEM_AVAIL") available, need $(human "$NEED_MEM_BYTES")"; fi
if [ "$ALREADY" = 1 ]; then ok "port ${PORT}: served by this recipe"
else
  # The server binds 127.0.0.1 (or the host network). A listener on 127.0.0.1, a wildcard or ::1
  # blocks it; one bound to another interface address does not, and is only reported.
  PORT_ALL="$(ss -ltnH "sport = :${PORT}" 2>/dev/null || true)"
  PORT_CLASH="$(printf '%s\n' "$PORT_ALL" | awk '{print $4}' | grep -E '^(127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]|\[::1\]|\[::ffff:127\.0\.0\.1\]):' || true)"
  PORT_DOCKER="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E "(127\.0\.0\.1|0\.0\.0\.0|\[::\]|:::?):${PORT}->" || true)"
  if [ -n "$PORT_CLASH$PORT_DOCKER" ]; then
    printf '    port %s is taken:\n%s\n%s\n' "$PORT" "$PORT_CLASH" "$PORT_DOCKER"
    fail "free port ${PORT} or run: PORT=<other> ./run.sh"
  elif [ -n "$PORT_ALL" ]; then
    ok "port ${PORT}: free on 127.0.0.1 (also bound elsewhere: $(printf '%s' "$PORT_ALL" | awk '{print $4}' | tr '\n' ' '))"
  else ok "port ${PORT}: free"; fi
fi

# --- 2. disk ---------------------------------------------------------------
say "Disk"
nearest_dir() { local d="$1"; while [ ! -d "$d" ]; do d="$(dirname "$d")"; done; echo "$d"; }
NEED_DISK=$ENGINE_DISK_BYTES
while read -r sha size repo rev rpath dest; do
  [ -z "${sha:-}" ] && continue
  have=0; [ -f "$MODELS_DIR/$dest" ] && have=$(stat -c %s "$MODELS_DIR/$dest")
  [ "$have" -lt "$size" ] && NEED_DISK=$(( NEED_DISK + size - have ))
done <<< "$WEIGHTS"
FREE_DISK=$(df -B1 --output=avail "$(nearest_dir "$MODELS_DIR")" | tail -1 | tr -d ' ')
if [ "$FREE_DISK" -ge "$NEED_DISK" ]; then ok "need $(human "$NEED_DISK") more, have $(human "$FREE_DISK")"
else fail "need $(human "$NEED_DISK") more disk under $MODELS_DIR, have $(human "$FREE_DISK"). Nothing was deleted."; fi

# --- 3. engine -------------------------------------------------------------
say "Engine"
engine_step

# --- 4. weights: pinned revision + SHA-256 -----------------------------------
hf_fetch() {   # repo rev path dest. The token reaches curl on stdin: never in argv or a file.
  { [ -n "${HF_TOKEN:-}" ] && printf 'header = "Authorization: Bearer %s"\n' "$HF_TOKEN"; true; } |
    curl --fail --location --retry 5 --retry-delay 5 --continue-at - --config - \
         --output "$4.part" "https://huggingface.co/$1/resolve/$2/$3"
  mv "$4.part" "$4"
}
default_weights_step() {
  while read -r sha size repo rev rpath dest; do
    [ -z "${sha:-}" ] && continue
    local f="$MODELS_DIR/$dest" mark="$MODELS_DIR/$dest.sha256-ok"
    if [ -f "$mark" ] && [ "$(cat "$mark")" = "$sha $size" ] && [ "$(stat -c %s "$f" 2>/dev/null)" = "$size" ]; then
      ok "verified earlier: $dest"; continue
    fi
    if [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" != "$size" ]; then
      if [ "$CHECK" = 1 ]; then plan "download $repo@${rev:0:12} $rpath ($(human "$size"))"; continue; fi
      mkdir -p "$(dirname "$f")"; printf '    get   %s (%s)\n' "$rpath" "$(human "$size")"
      hf_fetch "$repo" "$rev" "$rpath" "$f"
    elif [ "$CHECK" = 1 ]; then plan "verify SHA-256 of $dest"; continue; fi
    local got; got="$(sha256sum "$f" | cut -d' ' -f1)"
    if [ "$got" != "$sha" ]; then mv "$f" "$f.sha256-mismatch"; die "SHA-256 mismatch for $dest: expected $sha, got $got (kept as $f.sha256-mismatch)"; fi
    echo "$sha $size" > "$mark"; ok "sha256 ok: $dest"
  done <<< "$WEIGHTS"
}
declare -f weights_step >/dev/null || weights_step() { default_weights_step; }
say "Weights"
weights_step

# --- 5. serve --------------------------------------------------------------
say "Server"
if [ "$ALREADY" = 1 ]; then ok "already running"
elif [ "$CHECK" = 1 ]; then serve_step
else
  mkdir -p "$STATE_DIR"; serve_step
  printf '    wait  for %s (up to %ss; log: %s)\n' "$READY_URL" "$READY_TIMEOUT" "$LOGFILE"
  t=0
  until curl -fsS -o /dev/null "$READY_URL" 2>/dev/null; do
    server_running || die "server exited during start-up; see $LOGFILE"
    [ "$t" -ge "$READY_TIMEOUT" ] && die "not ready after ${READY_TIMEOUT}s; see $LOGFILE"
    sleep 5; t=$((t + 5))
  done
  ok "ready after ${t}s"
fi

# --- 6. done ---------------------------------------------------------------
if [ "$CHECK" = 1 ]; then
  if [ "$CHECK_FAILED" = 1 ]; then say "Check finished with FAIL lines above; nothing was changed. ./run.sh would stop at the first one."; exit 1; fi
  say "Check finished; nothing was changed. Run ./run.sh to do it."; exit 0
fi
say "Test it"
curl_test
say "Stop it"
echo "$STOP_CMD"
echo
echo "Expected: ${EXPECTED_LINE} - receipt: ${RECEIPT_PATH}"
