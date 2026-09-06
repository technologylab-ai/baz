import hashlib, importlib.util, json, os, sys, time
from pathlib import Path

root, receipts, label, timeout, token, *command = sys.argv[1:]
module_path = Path('/Users/rs/code/github.com/technologylab.ai/zig-http-app-api/reports/2026-09-06-basic-zap/reproducer/runner.py')
spec = importlib.util.spec_from_file_location('cleanup_runner', module_path)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
owner = json.loads(Path('/tmp/zig-http-measurement.lock/owner.json').read_text())
assert owner['token'] == token, 'Measurement reservation mismatch'
runner.ROOT = Path(root)
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
out = Path(receipts); out.mkdir(parents=True, exist_ok=True)
record = dict(command=command, workdir=root, label=label, started_utc=runner.now(), lock_owner=owner,
              watchdog_seconds=int(timeout), cleanup_runner_sha256=runner.sha(module_path))
started=time.monotonic(); error=None
print('RUN',label,command,flush=True)
try:
    record['returncode'] = runner.run_group(command, out/(label+'.log'), int(timeout), check=False)
except BaseException as err:
    error=repr(err); record['error']=error
finally:
    record.update(finished_utc=runner.now(),elapsed_seconds=round(time.monotonic()-started,3),
                  process_group_cleanup=runner.CLEANUP_LOG,
                  owned_groups_remaining=[p.pid for p in runner.OWNED])
    record['complete']=not error and not runner.OWNED and record.get('returncode')==0
    (out/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record),flush=True)
    if not record['complete']:
        print((out/(label+'.log')).read_text()[-12000:],flush=True)
sys.exit(0 if record['complete'] else 1)
