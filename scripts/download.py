#!/usr/bin/env python3
from __future__ import annotations
import argparse,hashlib,json,os,shutil,sys,time,urllib.error,urllib.parse,urllib.request
from pathlib import Path

def sha256(path: Path) -> str:
 h=hashlib.sha256()
 with path.open('rb') as f:
  while b:=f.read(8<<20): h.update(b)
 return h.hexdigest()
def download(url: str, dest: Path, expected: int) -> None:
 part=dest.with_suffix(dest.suffix+'.part'); start=part.stat().st_size if part.exists() else 0
 if start>expected: part.unlink(); start=0
 headers={'User-Agent':'sxuff-qwen38-recipe'}
 token=os.environ.get('HF_TOKEN');
 if token: headers['Authorization']='Bearer '+token
 if start: headers['Range']=f'bytes={start}-'
 req=urllib.request.Request(url,headers=headers)
 mode='ab' if start else 'wb'
 with urllib.request.urlopen(req,timeout=120) as r,part.open(mode) as out:
  if start and r.status!=206: out.close(); part.unlink(); return download(url,dest,expected)
  while chunk:=r.read(8<<20): out.write(chunk)
 if part.stat().st_size!=expected: raise RuntimeError(f'{dest.name}: expected {expected} bytes, got {part.stat().st_size}')
 os.replace(part,dest)
def main() -> int:
 p=argparse.ArgumentParser(); p.add_argument('role',choices=('target','draft')); p.add_argument('--destination',type=Path,required=True); p.add_argument('--report',type=Path); p.add_argument('--reserve-gib',type=int,default=20); a=p.parse_args()
 root=Path(__file__).resolve().parents[1]; m=json.loads((root/'manifests'/f'{a.role}.json').read_text()); a.destination.mkdir(parents=True,exist_ok=True)
 needed=sum(r['bytes'] for r in m['files'] if not (a.destination/r['name']).exists()); free=shutil.disk_usage(a.destination).free
 if free-needed<a.reserve_gib*1024**3: raise SystemExit(f'insufficient disk: free={free}, needed={needed}, reserve={a.reserve_gib*1024**3}')
 base=f"https://huggingface.co/{m['repository']}/resolve/{m['revision']}/"
 for i,row in enumerate(m['files'],1):
  path=a.destination/row['name']
  if path.exists() and path.stat().st_size==row['bytes'] and sha256(path)==row['sha256']:
   print(f'[{i}/{len(m["files"])}] verified {row["name"]}'); continue
  print(f'[{i}/{len(m["files"])}] downloading {row["name"]}',flush=True)
  download(base+urllib.parse.quote(row['name']),path,row['bytes'])
  if sha256(path)!=row['sha256']: path.unlink(missing_ok=True); raise RuntimeError(f'{row["name"]}: sha256 mismatch')
 report={'schema_version':1,'repository':m['repository'],'revision':m['revision'],'verified_files':len(m['files']),'verified_bytes':sum(r['bytes'] for r in m['files']),'complete':True}
 if a.report:
  a.report.parent.mkdir(parents=True,exist_ok=True)
  a.report.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
 print(json.dumps(report)); return 0
if __name__=='__main__': raise SystemExit(main())
