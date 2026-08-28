#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json
from pathlib import Path

def main() -> int:
 root=Path(__file__).resolve().parents[1]; seal=json.loads((root/'preregistration.json').read_text())
 protected={'protocol.json':'protocol_sha256','fixtures.json':'fixtures_sha256','manifests/target.json':'target_manifest_sha256','manifests/draft.json':'draft_manifest_sha256','runtime-manifest.json':'runtime_manifest_sha256'}
 for rel,key in protected.items():
  got=hashlib.sha256((root/rel).read_bytes()).hexdigest()
  if got!=seal[key]: raise SystemExit(f'protected contract mismatch: {rel}')
 runtime=json.loads((root/'runtime-manifest.json').read_text())
 if runtime['image_id']!=seal['resolved_image_id']: raise SystemExit('resolved image ID mismatch')
 print('RUNTIME_CONTRACT_OK',seal['study_id'],runtime['image_id']); return 0
if __name__=='__main__': raise SystemExit(main())
