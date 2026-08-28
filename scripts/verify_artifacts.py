#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, json
from pathlib import Path

def digest(path: Path) -> str:
    h=hashlib.sha256()
    with path.open('rb') as f:
        while chunk:=f.read(8<<20): h.update(chunk)
    return h.hexdigest()

def main() -> int:
    p=argparse.ArgumentParser(); p.add_argument('--manifest',type=Path,required=True); p.add_argument('--root',type=Path,required=True); p.add_argument('--report',type=Path)
    a=p.parse_args(); m=json.loads(a.manifest.read_text()); expected={r['name']:r for r in m['files']}
    actual={x.name:x for x in a.root.iterdir() if x.is_file()}
    missing=sorted(set(expected)-set(actual)); extra=sorted(set(actual)-set(expected))
    rows=[]; ok=not missing and not extra
    for name,row in sorted(expected.items()):
        path=actual.get(name)
        if path is None: continue
        got_size=path.stat().st_size; got_hash=digest(path); passed=got_size==row['bytes'] and got_hash==row['sha256']; ok &= passed
        rows.append({'name':name,'bytes':got_size,'sha256':got_hash,'passed':passed})
    report={'schema_version':1,'repository':m['repository'],'revision':m['revision'],'root_files':len(actual),'verified_files':sum(r['passed'] for r in rows),'verified_bytes':sum(r['bytes'] for r in rows if r['passed']),'missing':missing,'extra':extra,'complete':bool(ok),'files':rows}
    text=json.dumps(report,indent=2,sort_keys=True)+'\n'
    if a.report: a.report.parent.mkdir(parents=True,exist_ok=True); a.report.write_text(text)
    print(text,end=''); return 0 if ok else 1
if __name__=='__main__': raise SystemExit(main())
