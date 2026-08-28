#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -m unittest discover -s "$ROOT/tests" -p 'test_*.py'
python3 -m py_compile "$ROOT"/scripts/*.py
for f in "$ROOT"/scripts/*.sh; do bash -n "$f"; done
python3 -m json.tool "$ROOT/protocol.json" >/dev/null
python3 -m json.tool "$ROOT/fixtures.json" >/dev/null
python3 -m json.tool "$ROOT/manifests/target.json" >/dev/null
python3 -m json.tool "$ROOT/manifests/draft.json" >/dev/null
if [[ -f "$ROOT/results/summary.json" ]]; then python3 -m json.tool "$ROOT/results/summary.json" >/dev/null; fi
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$ROOT" status --short | grep -E '(^|/)(private|runs|\.state)/' >/dev/null; then echo 'private artifacts are visible to git' >&2; exit 1; fi
fi
echo REPOSITORY_CHECKS_OK
