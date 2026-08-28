#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

MODEL = 'qwen38-27b-stock-nvfp4'
SANDBOX_IMAGE = os.environ.get(
    'SANDBOX_IMAGE', 'sxuff/qwen38-27b-stock-dflash2:2026-08-28'
)


def meminfo() -> dict:
    values = {}
    for line in Path('/proc/meminfo').read_text().splitlines():
        key, raw = line.split(':', 1)
        values[key] = int(raw.strip().split()[0]) * 1024
    return {
        'mem_available_bytes': values['MemAvailable'],
        'swap_used_bytes': values['SwapTotal'] - values['SwapFree'],
    }


def stream_chat(url: str, payload: dict, timeout: int = 600) -> dict:
    body = dict(payload)
    body['stream'] = True
    body['stream_options'] = {'include_usage': True}
    request = urllib.request.Request(
        url,
        data=json.dumps(body, separators=(',', ':')).encode(),
        headers={'Content-Type': 'application/json'},
    )
    started = time.perf_counter()
    first = None
    content_parts = []
    reasoning_parts = []
    tools = {}
    usage = None
    finish_reason = None
    raw_events = []
    with urllib.request.urlopen(request, timeout=timeout) as response:
        while True:
            raw = response.readline()
            if not raw:
                break
            line = raw.decode('utf-8', 'replace').strip()
            if not line.startswith('data:'):
                continue
            data = line[5:].strip()
            if data == '[DONE]':
                break
            event = json.loads(data)
            raw_events.append(event)
            if event.get('usage'):
                usage = event['usage']
            for choice in event.get('choices') or []:
                if choice.get('finish_reason') is not None:
                    finish_reason = choice.get('finish_reason')
                delta = choice.get('delta') or {}
                meaningful = False
                if delta.get('content'):
                    content_parts.append(delta['content'])
                    meaningful = True
                reasoning = delta.get('reasoning_content') or delta.get('reasoning')
                if reasoning:
                    reasoning_parts.append(reasoning)
                    meaningful = True
                for call in delta.get('tool_calls') or []:
                    idx = int(call.get('index', 0))
                    item = tools.setdefault(idx, {'id': '', 'type': 'function', 'function': {'name': '', 'arguments': ''}})
                    if call.get('id'):
                        item['id'] += call['id']
                    function = call.get('function') or {}
                    if function.get('name'):
                        item['function']['name'] += function['name']
                    if function.get('arguments'):
                        item['function']['arguments'] += function['arguments']
                    meaningful = True
                if meaningful and first is None:
                    first = time.perf_counter()
    ended = time.perf_counter()
    if usage is None:
        raise RuntimeError('stream ended without usage')
    completion_tokens = int(usage.get('completion_tokens') or 0)
    ttft = None if first is None else first - started
    # SSE chunks may contain multiple accepted speculative tokens. Without
    # token IDs per chunk, subtracting one token at TTFT would bias DFlash2.
    # Use the auditable whole-request completion denominator instead.
    decode_seconds = None
    decode_tps = None
    return {
        'content': ''.join(content_parts),
        'reasoning_content': ''.join(reasoning_parts),
        'tool_calls': [tools[k] for k in sorted(tools)],
        'usage': usage,
        'finish_reason': finish_reason,
        'wall_seconds': ended - started,
        'ttft_seconds': ttft,
        'decode_seconds': decode_seconds,
        'decode_tps': decode_tps,
        'end_to_end_completion_tokens_per_second': (
            completion_tokens / max(ended - started, 1e-9)
        ),
        'raw_event_count': len(raw_events),
    }


def extract_code(text: str) -> str:
    match = re.search(r'```(?:python)?\s*(.*?)```', text, re.S | re.I)
    return (match.group(1) if match else text).strip()


def score_code(text: str) -> tuple[bool, str]:
    code = extract_code(text)
    tests = '''
ns = {}
exec(open('/work/solution.py', encoding='utf-8').read(), ns)
f = ns.get('merge_intervals')
assert callable(f)
def norm(x): return [list(v) for v in x]
assert norm(f([])) == []
assert norm(f([[1,3],[2,6],[8,10],[15,18]])) == [[1,6],[8,10],[15,18]]
assert norm(f([[1,4],[4,5]])) == [[1,5]]
assert norm(f([[5,7],[1,2],[2,4],[9,9]])) == [[1,4],[5,7],[9,9]]
assert norm(f([[-3,-1],[-2,2],[4,6]])) == [[-3,2],[4,6]]
print('CODE_PASS')
'''
    with tempfile.TemporaryDirectory(prefix='qwen-code-') as tmp:
        root = Path(tmp)
        (root / 'solution.py').write_text(code + '\n', encoding='utf-8')
        (root / 'tests.py').write_text(tests, encoding='utf-8')
        os.chmod(root, 0o755)
        os.chmod(root / 'solution.py', 0o644)
        os.chmod(root / 'tests.py', 0o644)
        command = [
            'docker', 'run', '--rm', '--network', 'none', '--read-only',
            '--tmpfs', '/tmp:rw,noexec,nosuid,size=32m', '--cap-drop', 'ALL',
            '--security-opt', 'no-new-privileges', '--pids-limit', '64',
            '--memory', '256m', '--cpus', '1',
            '--mount', f'type=bind,src={root},dst=/work,readonly',
            '--entrypoint', '/usr/bin/python3', SANDBOX_IMAGE,
            '-I', '/work/tests.py',
        ]
        result = subprocess.run(command, text=True, capture_output=True, timeout=30)
        ok = result.returncode == 0 and 'CODE_PASS' in result.stdout
        detail = (result.stdout + result.stderr)[-2000:]
        return ok, detail


def score(fixture: dict, result: dict) -> tuple[bool, str]:
    fid = fixture['id']
    content = (result.get('content') or '').strip()
    if fid == 'literal':
        return content == 'BENCH_READY', repr(content)
    if fid in {'copy_python', 'copy_json'}:
        expected = fixture['expected_output'].strip()
        return content == expected, (
            f'exact={content == expected} observed_chars={len(content)} '
            f'expected_chars={len(expected)}'
        )
    if fid == 'code':
        return score_code(content)
    if fid == 'json':
        try:
            value = json.loads(content)
        except Exception as exc:
            return False, f'json error: {exc}; content={content!r}'
        expected = {'runtime': 'SGLang', 'hardware': 'DGX Spark', 'speculative_mode': 'test'}
        return value == expected, repr(value)
    if fid == 'math':
        return re.search(r'(?<!\d)1517(?!\d)', content) is not None, content[-500:]
    if fid == 'prose':
        lowered = content.lower()
        sentences = [s for s in re.split(r'(?<=[.!?])\s+', content) if s.strip()]
        ok = (
            len(sentences) == 3
            and 'draft' in lowered
            and 'target' in lowered
            and ('verif' in lowered or 'accept' in lowered)
            and ('throughput' in lowered or 'faster' in lowered or 'speed' in lowered)
            and ('increase' in lowered or 'boost' in lowered or 'improv' in lowered)
            and 'preserv' in lowered
        )
        return ok, content[-1000:]
    if fid == 'reasoning':
        return (
            re.search(r'(?<!\d)437(?!\d)', content) is not None
            and bool(result.get('reasoning_content'))
        ), content[-500:]
    if fid == 'tool':
        calls = result.get('tool_calls') or []
        try:
            args = json.loads(calls[0]['function']['arguments'])
        except Exception as exc:
            return False, f'tool parse error: {exc}; calls={calls!r}'
        ok = len(calls) == 1 and calls[0]['function']['name'] == 'get_weather' and args == {'city': 'Paris'}
        return ok, repr(calls)
    if fid == 'vision':
        lowered = content.lower()
        return 'red' in lowered and 'blue' in lowered and 'square' in lowered, content
    return False, 'unknown fixture'


def make_payload(fixture: dict, image_dir: Path) -> dict:
    messages = fixture.get('messages')
    if fixture['id'] == 'vision':
        raw = (image_dir / fixture['vision_image']).read_bytes()
        data_url = 'data:image/png;base64,' + base64.b64encode(raw).decode()
        messages = [{
            'role': 'user',
            'content': [
                {'type': 'image_url', 'image_url': {'url': data_url}},
                {'type': 'text', 'text': fixture['vision_prompt']},
            ],
        }]
    payload = {
        'model': MODEL,
        'messages': messages,
        'temperature': 0,
        'top_p': 1,
        'seed': 17,
        'max_tokens': fixture['max_tokens'],
        'chat_template_kwargs': {'enable_thinking': fixture['thinking']},
    }
    if fixture.get('tools'):
        payload['tools'] = fixture['tools']
        payload['tool_choice'] = fixture.get('tool_choice', 'auto')
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--arm', required=True)
    parser.add_argument('--protocol', required=True)
    parser.add_argument('--fixtures', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--base-url', default='http://127.0.0.1:8001/v1')
    args = parser.parse_args()
    protocol_path = Path(args.protocol)
    fixtures_path = Path(args.fixtures)
    protocol_bytes = protocol_path.read_bytes()
    fixtures_bytes = fixtures_path.read_bytes()
    protocol = json.loads(protocol_bytes)
    fixtures = json.loads(fixtures_bytes)['fixtures']
    if args.arm not in protocol['arms']:
        raise SystemExit(f'arm {args.arm!r} is not sealed')
    repetitions = int(protocol['request_contract']['repetitions_per_fixture'])
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    before = meminfo()
    rows = []
    errors = []
    for fixture in fixtures:
        for repetition in range(repetitions):
            payload = make_payload(fixture, fixtures_path.parent)
            payload_sha = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            try:
                result = stream_chat(args.base_url + '/chat/completions', payload)
                passed, detail = score(fixture, result)
                row = {
                    'arm': args.arm,
                    'fixture_id': fixture['id'],
                    'performance': fixture['performance'],
                    'repetition': repetition,
                    'payload_sha256': payload_sha,
                    'quality_pass': passed,
                    'quality_detail': detail,
                    'content_sha256': hashlib.sha256((result.get('content') or '').encode()).hexdigest(),
                    **result,
                }
            except Exception as exc:
                row = {
                    'arm': args.arm,
                    'fixture_id': fixture['id'],
                    'performance': fixture['performance'],
                    'repetition': repetition,
                    'payload_sha256': payload_sha,
                    'quality_pass': False,
                    'error': f'{type(exc).__name__}: {exc}',
                }
                errors.append(row['error'])
            rows.append(row)
            output = {
                'schema_version': 1,
                'arm': args.arm,
                'protocol_sha256': hashlib.sha256(protocol_bytes).hexdigest(),
                'fixtures_sha256': hashlib.sha256(fixtures_bytes).hexdigest(),
                'started_memory': before,
                'current_memory': meminfo(),
                'rows': rows,
                'errors': errors,
                'complete': False,
            }
            output_path.write_text(json.dumps(output, indent=2, sort_keys=True) + '\n')
    after = meminfo()
    output.update({
        'current_memory': after,
        'swap_growth_bytes': max(0, after['swap_used_bytes'] - before['swap_used_bytes']),
        'complete': True,
    })
    output_path.write_text(json.dumps(output, indent=2, sort_keys=True) + '\n')
    print(json.dumps({
        'arm': args.arm,
        'rows': len(rows),
        'quality_passes': sum(bool(r.get('quality_pass')) for r in rows),
        'errors': len(errors),
        'swap_growth_bytes': output['swap_growth_bytes'],
        'mem_available_bytes': after['mem_available_bytes'],
        'output': str(output_path),
    }, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
