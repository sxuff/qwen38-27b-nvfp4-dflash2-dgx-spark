#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${MODEL_DIR:?set MODEL_DIR to the pinned target snapshot}"
DRAFT="${DRAFT_DIR:?set DRAFT_DIR to the pinned draft snapshot}"
IMAGE="${IMAGE:-sxuff/qwen38-27b-stock-dflash2:2026-08-28}"
RUN_ROOT="${RUN_ROOT:-$ROOT/private/primary}"
NAME=qwen38-27b-stock-nvfp4
RESTORE_UNIT="${RESTORE_UNIT:-}"
RESTORE_BASE_URL="${RESTORE_BASE_URL:-}"
RESTORE_API_KEY_FILE="${RESTORE_API_KEY_FILE:-}"
mkdir -p "$RUN_ROOT" "$ROOT/results"
baseline_swap=$(awk '/SwapTotal:/{t=$2}/SwapFree:/{f=$2}END{print (t-f)*1024}' /proc/meminfo)
restore(){
 NAME="$NAME" "$ROOT/scripts/stop.sh" || true
 [[ -z "$RESTORE_UNIT" ]] || systemctl --user start "$RESTORE_UNIT" || true
}
trap restore EXIT
[[ -z "$RESTORE_UNIT" ]] || systemctl --user stop "$RESTORE_UNIT"
python3 "$ROOT/scripts/verify_contract.py"
run_arm(){
 arm=$1; rm -f "$RUN_ROOT/$arm-stop" "$RUN_ROOT/$arm-incident.json" "$RUN_ROOT/$arm-telemetry.jsonl"
 MODE="$arm" MODEL_DIR="$TARGET" DRAFT_DIR="$DRAFT" IMAGE="$IMAGE" NAME="$NAME" STATE_DIR="$RUN_ROOT/$arm-state" "$ROOT/scripts/serve.sh"
 deadline=$((SECONDS+1200))
 while ((SECONDS<deadline)); do
  curl -fsS --max-time 3 http://127.0.0.1:8001/v1/models >/dev/null 2>&1 && break
  docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -qx true || { docker logs "$NAME" > "$RUN_ROOT/$arm-server.log" 2>&1 || true; return 1; }
  sleep 5
 done
 curl -fsS http://127.0.0.1:8001/v1/models | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"][0]["id"]=="qwen38-27b-stock-nvfp4",d'
 python3 "$ROOT/scripts/watchdog.py" --output "$RUN_ROOT/$arm-telemetry.jsonl" --stop "$RUN_ROOT/$arm-stop" --incident "$RUN_ROOT/$arm-incident.json" --container "$NAME" --baseline-swap "$baseline_swap" & watchdog=$!
 set +e
 python3 "$ROOT/scripts/benchmark.py" --arm "$arm" --protocol "$ROOT/protocol.json" --fixtures "$ROOT/fixtures.json" --output "$RUN_ROOT/$arm.json"
 bench_rc=$?
 set -e
 touch "$RUN_ROOT/$arm-stop"; wait "$watchdog" || watch_rc=$?; watch_rc=${watch_rc:-0}
 curl -fsS http://127.0.0.1:8001/metrics > "$RUN_ROOT/$arm-metrics.txt" || true
 docker logs "$NAME" > "$RUN_ROOT/$arm-server.log" 2>&1 || true
 docker inspect "$NAME" > "$RUN_ROOT/$arm-container.json"
 NAME="$NAME" "$ROOT/scripts/stop.sh"
 [[ $bench_rc -eq 0 && $watch_rc -eq 0 && ! -e "$RUN_ROOT/$arm-incident.json" ]]
}
run_arm no-spec
run_arm dflash2
python3 "$ROOT/scripts/analyze.py" --root "$RUN_ROOT" --output "$ROOT/results/summary.json" --report "$ROOT/REPORT.md"
trap - EXIT
restore
if [[ -n "$RESTORE_BASE_URL" ]]; then
 headers=()
 [[ -z "$RESTORE_API_KEY_FILE" ]] || headers=(-H "Authorization: Bearer $(cat "$RESTORE_API_KEY_FILE")")
 restored=0
 for _ in $(seq 1 120); do curl -fsS --max-time 3 "${headers[@]}" "$RESTORE_BASE_URL/v1/models" >/dev/null 2>&1 && { restored=1; break; }; sleep 2; done
 [[ $restored -eq 1 ]] || { echo 'restored endpoint failed readiness' >&2; exit 1; }
fi
[[ -z "$RESTORE_UNIT" ]] || systemctl --user is-active "$RESTORE_UNIT"
touch "$RUN_ROOT/STUDY_COMPLETE"
