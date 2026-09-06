from pathlib import Path
import hashlib
import io
import json
import re
import subprocess
import sys
import zipfile

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
HEAD = '86249ad4ea6a85407dd9463b43311c0c2be1e293'
REPO = 'technologylab-ai/baz'

def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', 'repos/' + REPO + '/' + path]))

def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')

def text(path):
    return path.read_bytes().decode('utf-8-sig')

def terminal(path):
    return json.loads(next(line for line in reversed(text(path).splitlines()) if line.startswith('{')))

summary = json.loads((OUT / 'verification.json').read_text()) if (OUT / 'verification.json').exists() else {'head_revision': HEAD, 'hosts': {}}
for run_id, label in ((34050620006, 'ci'), (34050619965, 'windows')):
    run = api('actions/runs/' + str(run_id))
    assert run['head_sha'] == HEAD and run['event'] == 'pull_request'
    save(OUT / ('run-' + label + '.json'), run)
    artifacts = api('actions/runs/' + str(run_id) + '/artifacts')
    save(OUT / ('artifacts-' + label + '.json'), artifacts)
    print('RUN', label, run['status'], run['conclusion'], flush=True)
    for artifact in artifacts['artifacts']:
        assert artifact['workflow_run']['head_sha'] == HEAD
        host = 'windows' if 'windows' in artifact['name'] else ('macos' if 'macos' in artifact['name'] else 'linux')
        dest = OUT / host
        dest.mkdir(exist_ok=True)
        zip_path = dest / 'artifact.zip'
        if zip_path.exists():
            archive = zip_path.read_bytes()
        else:
            archive = subprocess.check_output(['gh', 'api', 'repos/' + REPO + '/actions/artifacts/' + str(artifact['id']) + '/zip'])
            zip_path.write_bytes(archive)
        archive_hash = hashlib.sha256(archive).hexdigest()
        assert artifact['digest'] == 'sha256:' + archive_hash
        save(dest / 'artifact.json', artifact)
        with zipfile.ZipFile(io.BytesIO(archive)) as stream:
            for name in stream.namelist():
                assert not Path(name).is_absolute() and '..' not in Path(name).parts
                target = dest / name
                if target.exists():
                    assert target.read_bytes() == stream.read(name)
            stream.extractall(dest)
        environment = text(dest / ('environment.txt' if host == 'windows' else 'environment.log'))
        executed = re.search(r'commit=([a-f0-9]{40})', environment).group(1) if host == 'windows' else environment.splitlines()[0]
        assert '0.16.0' in environment
        commit = api('git/commits/' + executed)
        save(dest / 'executed-commit.json', commit)
        head_tree = subprocess.check_output(['git', 'rev-parse', HEAD + '^{tree}'], cwd=ROOT, text=True).strip()
        assert commit['tree']['sha'] == head_tree, 'Executed tree differs from PR head'
        value = {'run_id': run_id, 'head_revision': HEAD, 'executed_revision': executed, 'executed_git_tree': commit['tree']['sha'],
                 'head_git_tree': head_tree, 'entire_tree_identical': True, 'environment_raw': environment, 'artifact_sha256': archive_hash,
                 'verify': {}, 'suites': {}}
        modes = ('Debug', 'ReleaseSafe') if host == 'windows' else ('debug', 'release-safe')
        for mode in modes:
            lines = [line for line in text(dest / (mode + '.log')).splitlines() if line.startswith('Build Summary')]
            assert lines == ['Build Summary: 3/3 steps succeeded; 1/1 tests passed', 'Build Summary: 44/44 steps succeeded; 68/68 tests passed'], lines
            value['verify'][mode] = {'root_steps': 44, 'root_tests': 68, 'consumer_steps': 3, 'consumer_tests': 1}
        names = [('app', 'app_integration' if host == 'windows' else 'app', 14),
                 ('examples', 'examples_integration' if host == 'windows' else 'examples', 20),
                 ('streaming', 'streaming_integration' if host == 'windows' else 'streaming', 14),
                 ('borrow', 'borrow_integration' if host == 'windows' else 'borrow', 9)]
        if host == 'windows':
            names.append(('shards', 'windows_smoke', 3))
        for name, log, expected in names:
            receipt = terminal(dest / (log + '.log'))
            save(dest / (name + '.json'), receipt)
            assert receipt['passed'] == expected
            value['suites'][name] = expected
            if name in ('streaming', 'borrow', 'shards'):
                assert not receipt['performance_comparison']
                if name != 'shards':
                    assert receipt['optimize'] == 'ReleaseSafe'
                cases = receipt['cases']
                assert len(cases) == expected
                for case in cases:
                    for key in ('live_connections', 'live_operations', 'allocation_calls_after_start'):
                        assert case['stats'][key] == 0, (host, name, case['name'], key)
                value[name + '_final_ownership_zero'] = True
                if name == 'streaming':
                    assert all(case['fixture'] is None or case['fixture']['started'] == case['fixture']['finished'] for case in cases)
                if name == 'borrow':
                    counted = [case for case in cases if case['copy_counter_scope'] is not None]
                    assert len(counted) == 7
                    for case in counted:
                        assert case['stats']['borrow_copies'] == case['stats']['response_draft_copy_bytes'] == 0
                    value['borrow_cases_with_zero_copy_counters'] = 7
                    value['borrow_copy_counter_scope'] = 'Small-borrow copies and draft-body compaction only. Error fallback cases are excluded.'
                    value['backend'] = sorted(set(case['backend'] for case in cases))
        summary['hosts'][host] = value
        print('VERIFIED', host, executed, value['suites'], archive_hash, flush=True)
    if run['status'] == 'completed' and run['conclusion'] != 'success':
        raise RuntimeError('Native PR run failed: ' + label)
save(OUT / 'verification.json', summary)
save(OUT / 'receipt.sha256.json', {str(file.relative_to(OUT)): hashlib.sha256(file.read_bytes()).hexdigest()
                                for file in sorted(OUT.rglob('*')) if file.is_file() and file.name != 'receipt.sha256.json'})
