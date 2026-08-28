#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, math, re, statistics
from pathlib import Path

def med(xs):
    vals=[float(x) for x in xs if isinstance(x,(int,float)) and math.isfinite(float(x))]
    return statistics.median(vals) if vals else None

def metrics(path: Path) -> dict:
    out={}
    if not path.exists(): return out
    for line in path.read_text(errors='replace').splitlines():
        if line.startswith('#'): continue
        m=re.match(r'^([^\s{]+)(?:\{[^}]*\})?\s+([-+0-9.eE]+)$',line)
        if m:
            try: out[m.group(1)]=float(m.group(2))
            except ValueError: pass
    return out

def telemetry(path: Path) -> dict:
    rows=[]
    if path.exists():
        rows=[json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    return {
        'samples':len(rows),
        'minimum_mem_available_bytes':min((r['mem_available_bytes'] for r in rows),default=None),
        'maximum_swap_growth_bytes':max((r['swap_growth_bytes'] for r in rows),default=None),
    }

def main() -> int:
    p=argparse.ArgumentParser(); p.add_argument('--root',type=Path,required=True); p.add_argument('--output',type=Path,required=True); p.add_argument('--report',type=Path,required=True)
    a=p.parse_args(); runs={arm:json.loads((a.root/f'{arm}.json').read_text()) for arm in ('no-spec','dflash2')}
    ids={(r['fixture_id'],r['repetition']) for r in runs['no-spec']['rows']}
    if ids != {(r['fixture_id'],r['repetition']) for r in runs['dflash2']['rows']}: raise SystemExit('paired row keys differ')
    if len(ids) != 27 or any(len(run['rows']) != 27 for run in runs.values()): raise SystemExit('planned row denominator is incomplete')
    if not all(run.get('complete') is True for run in runs.values()): raise SystemExit('analyzer received an incomplete run envelope')
    if any(len(run.get('errors') or []) for run in runs.values()): raise SystemExit('analyzer received runtime errors')
    if any(len({(r['fixture_id'],r['repetition']) for r in run['rows']}) != len(run['rows']) for run in runs.values()): raise SystemExit('duplicate row keys')
    root=Path(__file__).resolve().parents[1]
    seal=json.loads((root/'preregistration.json').read_text())
    runtime=json.loads((root/'runtime-manifest.json').read_text())
    summary={'schema_version':2,'study_id':seal['study_id'],'source_commit':seal['source_commit'],'source_tree_sha256':seal['source_tree_sha256'],'resolved_image_id':runtime['image_id'],'arm_order':['no-spec','dflash2'],'metric_definitions':{'end_to_end_completion_tokens_per_second':'completion tokens divided by whole request wall time, including prefill and first-token latency'},'arms':{},'paired':{}}
    for arm,run in runs.items():
        rows=run['rows']; perf=[r for r in rows if r.get('performance')]
        per={}
        for fid in sorted({r['fixture_id'] for r in rows}):
            rs=[r for r in rows if r['fixture_id']==fid]
            per[fid]={'rows':len(rs),'completion_tokens':sum(int((r.get('usage') or {}).get('completion_tokens') or 0) for r in rs),'median_ttft_seconds':med(r.get('ttft_seconds') for r in rs),'median_end_to_end_completion_tokens_per_second':med(r.get('end_to_end_completion_tokens_per_second') for r in rs),'quality_passes':sum(bool(r.get('quality_pass')) for r in rs)}
        m=metrics(a.root/f'{arm}-metrics.txt')
        t=telemetry(a.root/f'{arm}-telemetry.jsonl')
        summary['arms'][arm]={'rows':len(rows),'performance_rows':len(perf),'errors':len(run.get('errors') or []),'quality_passes':sum(bool(r.get('quality_pass')) for r in rows),'all_quality_pass':all(bool(r.get('quality_pass')) for r in rows),'completion_tokens':sum(int((r.get('usage') or {}).get('completion_tokens') or 0) for r in rows),'median_end_to_end_completion_tokens_per_second':med(r.get('end_to_end_completion_tokens_per_second') for r in perf),'minimum_mem_available_bytes':t['minimum_mem_available_bytes'],'swap_growth_bytes':t['maximum_swap_growth_bytes'],'telemetry_samples':t['samples'],'spec_accept_length_final':m.get('sglang:spec_accept_length'),'spec_accept_rate_final':m.get('sglang:spec_accept_rate'),'per_fixture':per}
    pairs=[]
    left={(r['fixture_id'],r['repetition']):r for r in runs['no-spec']['rows']}; right={(r['fixture_id'],r['repetition']):r for r in runs['dflash2']['rows']}
    for key in sorted(ids):
        x,y=left[key],right[key]
        pairs.append({'fixture_id':key[0],'repetition':key[1],'payload_match':x.get('payload_sha256')==y.get('payload_sha256'),'exact_output_match':x.get('content_sha256')==y.get('content_sha256'),'no_spec_end_to_end_completion_tokens_per_second':x.get('end_to_end_completion_tokens_per_second'),'dflash2_end_to_end_completion_tokens_per_second':y.get('end_to_end_completion_tokens_per_second'),'speed_ratio':(y.get('end_to_end_completion_tokens_per_second')/x.get('end_to_end_completion_tokens_per_second')) if x.get('end_to_end_completion_tokens_per_second') and y.get('end_to_end_completion_tokens_per_second') else None,'no_spec_quality_pass':x.get('quality_pass'),'dflash2_quality_pass':y.get('quality_pass')})
    perf_pairs=[r for r in pairs if left[(r['fixture_id'],r['repetition'])].get('performance')]
    b=summary['arms']['no-spec']; d=summary['arms']['dflash2']
    if not all(r['payload_match'] for r in pairs): raise SystemExit('paired payload hashes differ')
    summary['paired']={'rows':len(pairs),'payload_matches':sum(r['payload_match'] for r in pairs),'exact_output_matches':sum(r['exact_output_match'] for r in pairs),'performance_rows':len(perf_pairs),'performance_exact_output_matches':sum(r['exact_output_match'] for r in perf_pairs),'median_paired_speed_ratio':med(r['speed_ratio'] for r in perf_pairs),'aggregate_median_speed_ratio':d['median_end_to_end_completion_tokens_per_second']/b['median_end_to_end_completion_tokens_per_second'],'rows_detail':pairs}
    summary['gate']={'operational_complete':all(x['rows']==27 and x['errors']==0 for x in summary['arms'].values()),'quality_complete':all(x['all_quality_pass'] for x in summary['arms'].values()),'safety_eligible':all((x['minimum_mem_available_bytes'] or 0)>=15*1024**3 and (x['swap_growth_bytes'] or 0)<=512*1024**2 for x in summary['arms'].values())}
    summary['posthoc_diagnostic']={'shared_failed_fixture_ids':sorted(set(fid for fid in b['per_fixture'] if b['per_fixture'][fid]['quality_passes']<b['per_fixture'][fid]['rows'] and d['per_fixture'][fid]['quality_passes']<d['per_fixture'][fid]['rows'])),'note':'The frozen quality gate is unchanged. Shared failures are reported for diagnosis and do not become passes.'}
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(summary,indent=2,sort_keys=True)+'\n')
    lines=['# Measured comparison','',f"- no-spec median end-to-end completion rate: **{b['median_end_to_end_completion_tokens_per_second']:.2f} tok/s**",f"- DFlash2 median end-to-end completion rate: **{d['median_end_to_end_completion_tokens_per_second']:.2f} tok/s**",f"- aggregate median ratio: **{summary['paired']['aggregate_median_speed_ratio']:.2f}x**",f"- median paired row ratio: **{summary['paired']['median_paired_speed_ratio']:.2f}x**",f"- exact outputs: **{summary['paired']['exact_output_matches']}/{summary['paired']['rows']}**",f"- quality: **{b['quality_passes']}/{b['rows']} no-spec**, **{d['quality_passes']}/{d['rows']} DFlash2**",f"- operational completion: **{summary['gate']['operational_complete']}**",f"- safety eligible: **{summary['gate']['safety_eligible']}**",f"- frozen quality gate complete: **{summary['gate']['quality_complete']}**",f"- minimum MemAvailable: **{b['minimum_mem_available_bytes'] / 1024**3:.2f} GiB no-spec**, **{d['minimum_mem_available_bytes'] / 1024**3:.2f} GiB DFlash2**",f"- maximum swap growth: **{b['swap_growth_bytes']} bytes no-spec**, **{d['swap_growth_bytes']} bytes DFlash2**",f"- DFlash2 final acceptance: **{d['spec_accept_length_final']} tokens**, **{d['spec_accept_rate_final']} rate**",'', '## Per-fixture median end-to-end completion tok/s','', '| Fixture | No spec | DFlash2 | Ratio |','|---|---:|---:|---:|']
    for fid in sorted(b['per_fixture']):
        x=b['per_fixture'][fid]['median_end_to_end_completion_tokens_per_second']; y=d['per_fixture'][fid]['median_end_to_end_completion_tokens_per_second']; ratio=(y/x) if x and y else None
        lines.append(f"| {fid} | {x:.2f} | {y:.2f} | {ratio:.2f}x |" if ratio else f"| {fid} | {x or 'n/a'} | {y or 'n/a'} | n/a |")
    lines += ['', 'The frozen lexical prose checker failed all three prose rows in both arms. This shared failure remains a quality-gate failure; post-hoc inspection does not relabel it.', '', 'One paired three-repetition operational sweep on one NVIDIA GB10. Results are workload-specific. Exact parity and quality are separate outcomes. The fixed no-spec then DFlash2 order does not isolate run-order drift.']
    a.report.write_text('\n'.join(lines)+'\n'); print(json.dumps(summary['paired'],indent=2)); return 0
if __name__=='__main__': raise SystemExit(main())
