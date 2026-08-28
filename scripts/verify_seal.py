#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json
from pathlib import Path

def main() -> int:
 root=Path(__file__).resolve().parents[1]; seal=json.loads((root/'preregistration.json').read_text())
 if seal.get('primary_trace_count_at_freeze')!=0: raise SystemExit('seal does not declare zero primary traces')
 for row in seal['tracked_files']:
  p=root/row['path']
  if not p.is_file(): raise SystemExit(f'missing sealed file: {row["path"]}')
  b=p.read_bytes()
  if len(b)!=row['bytes'] or hashlib.sha256(b).hexdigest()!=row['sha256']: raise SystemExit(f'sealed file mismatch: {row["path"]}')
 protected={'protocol.json':'protocol_sha256','fixtures.json':'fixtures_sha256','manifests/target.json':'target_manifest_sha256','manifests/draft.json':'draft_manifest_sha256','runtime-manifest.json':'runtime_manifest_sha256'}
 for rel,key in protected.items():
  if hashlib.sha256((root/rel).read_bytes()).hexdigest()!=seal[key]: raise SystemExit(f'protected hash mismatch: {rel}')
 print('SEAL_OK',seal['source_commit'],seal['source_tree_sha256']); return 0
if __name__=='__main__': raise SystemExit(main())
