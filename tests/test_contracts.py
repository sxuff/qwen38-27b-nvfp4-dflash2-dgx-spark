import hashlib,importlib.util,json,re,subprocess,tempfile,unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location('benchmark',ROOT/'scripts/benchmark.py')
assert SPEC is not None and SPEC.loader is not None
benchmark=importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(benchmark)

class ContractTests(unittest.TestCase):
    def test_protocol_counts(self):
        protocol=json.loads((ROOT/'protocol.json').read_text()); fixtures=json.loads((ROOT/'fixtures.json').read_text())['fixtures']
        self.assertEqual(set(protocol['arms']),{'no-spec','dflash2'})
        self.assertEqual(len(fixtures),9)
        self.assertEqual(len(fixtures)*protocol['request_contract']['repetitions_per_fixture'],27)
        self.assertEqual(protocol['acceptance']['complete_rows_per_arm'],27)

    def test_artifact_verifier_accepts_exact_and_rejects_extra(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); (root/'a').write_bytes(b'abc')
            manifest={'repository':'x/y','revision':'a'*40,'files':[{'name':'a','bytes':3,'sha256':hashlib.sha256(b'abc').hexdigest()}]}
            mp=root/'manifest.json'; mp.write_text(json.dumps(manifest))
            cmd=['python3',str(ROOT/'scripts/verify_artifacts.py'),'--manifest',str(mp),'--root',str(root)]
            self.assertEqual(subprocess.run(cmd,capture_output=True).returncode,1)
            mp.unlink()
            # The manifest itself must live outside the verified root.
            mp2=Path(td).parent/(Path(td).name+'-manifest.json'); mp2.write_text(json.dumps(manifest))
            try:
                self.assertEqual(subprocess.run(cmd[:3]+[str(mp2)]+cmd[4:],capture_output=True).returncode,0)
                (root/'extra').write_text('x')
                self.assertEqual(subprocess.run(cmd[:3]+[str(mp2)]+cmd[4:],capture_output=True).returncode,1)
            finally: mp2.unlink(missing_ok=True)

    def test_quality_scorers_reject_numeric_substrings_and_bad_prose(self):
        self.assertFalse(benchmark.score({'id':'math'},{'content':'15170'})[0])
        self.assertFalse(benchmark.score({'id':'reasoning'},{'content':'4370','reasoning_content':'x'})[0])
        bad='A draft is checked by target verification. This does not increase throughput. It may reduce speed.'
        self.assertFalse(benchmark.score({'id':'prose'},{'content':bad})[0])

    def test_runtime_manifest_binds_resolved_image(self):
        manifest=json.loads((ROOT/'runtime-manifest.json').read_text())
        self.assertRegex(manifest['image_id'],r'^sha256:[0-9a-f]{64}$')
        self.assertEqual(manifest['target_revision'],json.loads((ROOT/'manifests/target.json').read_text())['revision'])
        self.assertEqual(manifest['draft_revision'],json.loads((ROOT/'manifests/draft.json').read_text())['revision'])

    def test_mamba_pool_matches_scheduler_ceiling(self):
        serve=(ROOT/'scripts/serve.sh').read_text()
        mamba=re.search(r'--max-mamba-cache-size\s+(\d+)',serve)
        running=re.search(r'--max-running-requests\s+(\d+)',serve)
        assert mamba is not None and running is not None
        self.assertEqual(int(mamba.group(1)),5*int(running.group(1)))

    def test_analyzer_rejects_incomplete_envelopes(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            envelope={'complete':False,'errors':[],'rows':[]}
            for arm in ('no-spec','dflash2'):
                (root/f'{arm}.json').write_text(json.dumps(envelope))
            result=subprocess.run(['python3',str(ROOT/'scripts/analyze.py'),'--root',str(root),'--output',str(root/'summary.json'),'--report',str(root/'report.md')],capture_output=True)
            self.assertNotEqual(result.returncode,0)

if __name__=='__main__': unittest.main()
