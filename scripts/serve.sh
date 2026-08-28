#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${MODE:-dflash2}"
MODEL_DIR="${MODEL_DIR:?set MODEL_DIR to the pinned target snapshot}"
DRAFT_DIR="${DRAFT_DIR:-}"
IMAGE="${IMAGE:-sxuff/qwen38-27b-stock-dflash2:2026-08-28}"
NAME="${NAME:-qwen38-27b-stock-nvfp4}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8001}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.70}"
CPUSET="${CPUSET:-5-9,15-19}"
STATE_DIR="${STATE_DIR:-$ROOT/.state}"
case "$MODE" in no-spec|dflash2) ;; *) echo 'MODE must be no-spec or dflash2' >&2; exit 2;; esac
mkdir -p "$STATE_DIR"
python3 "$ROOT/scripts/verify_contract.py" >/dev/null
python3 "$ROOT/scripts/verify_artifacts.py" --manifest "$ROOT/manifests/target.json" --root "$MODEL_DIR" --report "$STATE_DIR/target-verification.json" >/dev/null
if [[ "$MODE" == dflash2 ]]; then
  [[ -n "$DRAFT_DIR" ]] || { echo 'DRAFT_DIR is required for dflash2' >&2; exit 2; }
  python3 "$ROOT/scripts/verify_artifacts.py" --manifest "$ROOT/manifests/draft.json" --root "$DRAFT_DIR" --report "$STATE_DIR/draft-verification.json" >/dev/null
fi
EXPECTED_IMAGE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["image_id"])' "$ROOT/runtime-manifest.json")"
ACTUAL_IMAGE_ID="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
[[ "$ACTUAL_IMAGE_ID" == "$EXPECTED_IMAGE_ID" ]] || { echo "image identity mismatch: expected=$EXPECTED_IMAGE_ID actual=$ACTUAL_IMAGE_ID" >&2; exit 2; }
docker image inspect "$IMAGE" --format '{{json .Config.Labels}}' > "$STATE_DIR/image-labels.json"
if docker inspect "$NAME" >/dev/null 2>&1; then
  owned=$(docker inspect -f '{{index .Config.Labels "io.sxuff.qwen38.recipe"}}' "$NAME" 2>/dev/null || true)
  [[ "$owned" == true ]] || { echo "refusing to touch unowned container $NAME" >&2; exit 2; }
  docker rm -f "$NAME" >/dev/null
fi
args=(python3 -m sglang.launch_server --trust-remote-code --model-path /model --served-model-name qwen38-27b-stock-nvfp4 --mem-fraction-static "$MEM_FRACTION_STATIC" --attention-backend flashinfer --chunked-prefill-size 8192 --disable-prefill-cuda-graph --kv-cache-dtype fp8_e4m3 --mamba-ssm-dtype bfloat16 --mamba-full-memory-ratio 4.21 --mamba-radix-cache-strategy extra_buffer --max-mamba-cache-size 50 --max-running-requests 10 --context-length 262144 --reasoning-parser qwen3 --tool-call-parser qwen3_coder --sampling-defaults model --enable-metrics --enable-cache-report --host "$HOST" --port "$PORT")
volumes=(-v "$MODEL_DIR:/model:ro")
if [[ "$MODE" == dflash2 ]]; then
  draft_parent="$(dirname "$DRAFT_DIR")"
  if [[ "$(basename "$draft_parent")" == snapshots ]]; then
    draft_repo_root="$(dirname "$draft_parent")"
    draft_revision="$(basename "$DRAFT_DIR")"
    volumes+=(-v "$draft_repo_root:/draft-repo:ro")
    draft_container_path="/draft-repo/snapshots/$draft_revision"
  else
    volumes+=(-v "$DRAFT_DIR:/draft:ro")
    draft_container_path=/draft
  fi
  args+=(--speculative-algorithm DFLASH --speculative-draft-model-path "$draft_container_path" --speculative-num-draft-tokens 8)
fi
id=$(docker create --name "$NAME" --gpus all --ipc host --network host --cpuset-cpus "$CPUSET" --memory 110g --memory-swap 110g --label io.sxuff.qwen38.recipe=true --label "io.sxuff.qwen38.mode=$MODE" "${volumes[@]}" "$IMAGE" "${args[@]}")
python3 - "$STATE_DIR/launch.json" "$id" "$MODE" "$IMAGE" "$MODEL_DIR" "$DRAFT_DIR" "${args[@]}" <<'PY'
import json,sys,datetime
out,cid,mode,image,model,draft,*args=sys.argv[1:]
d={'schema_version':1,'created_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'container_id':cid,'mode':mode,'image':image,'image_id':__import__('subprocess').check_output(['docker','image','inspect',image,'--format','{{.Id}}'],text=True).strip(),'model_dir':model,'draft_dir':draft or None,'server_args':args}
open(out,'w').write(json.dumps(d,indent=2,sort_keys=True)+'\n')
PY
docker start "$id" >/dev/null
echo "started $NAME mode=$MODE id=$id"
