#!/usr/bin/env python3
from __future__ import annotations
import argparse,json,subprocess,time
from pathlib import Path

def mem():
 d={}
 for line in Path('/proc/meminfo').read_text().splitlines():
  k,v=line.split(':',1); d[k]=int(v.strip().split()[0])*1024
 return {'mem_available_bytes':d['MemAvailable'],'swap_used_bytes':d['SwapTotal']-d['SwapFree']}
def main():
 p=argparse.ArgumentParser(); p.add_argument('--output',type=Path,required=True); p.add_argument('--stop',type=Path,required=True); p.add_argument('--incident',type=Path,required=True); p.add_argument('--container',required=True); p.add_argument('--baseline-swap',type=int,required=True); p.add_argument('--mem-floor',type=int,default=15*1024**3); p.add_argument('--max-swap-growth',type=int,default=512*1024**2); a=p.parse_args()
 a.output.parent.mkdir(parents=True,exist_ok=True)
 while not a.stop.exists():
  row={'time_ns':time.time_ns(),**mem()}; row['swap_growth_bytes']=max(0,row['swap_used_bytes']-a.baseline_swap)
  with a.output.open('a') as f: f.write(json.dumps(row,sort_keys=True)+'\n')
  if row['mem_available_bytes']<a.mem_floor or row['swap_growth_bytes']>a.max_swap_growth:
   incident={'schema_version':1,'condition':'memory_or_swap_guard','observed':row,'mem_floor':a.mem_floor,'max_swap_growth':a.max_swap_growth,'container':a.container,'termination_action':'not attempted'}
   owned=subprocess.run(['docker','inspect','-f','{{index .Config.Labels "io.sxuff.qwen38.recipe"}}',a.container],text=True,capture_output=True)
   if owned.returncode==0 and owned.stdout.strip()=='true':
    stopped=subprocess.run(['docker','rm','-f',a.container],text=True,capture_output=True)
    incident['termination_action']='docker rm -f' if stopped.returncode==0 else 'docker rm -f failed'
   else: incident['termination_action']='refused: ownership label missing'
   a.incident.write_text(json.dumps(incident,indent=2,sort_keys=True)+'\n'); return 2
  time.sleep(2)
 return 0
if __name__=='__main__': raise SystemExit(main())
