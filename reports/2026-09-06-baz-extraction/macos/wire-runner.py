import datetime, json, os, runpy, signal, subprocess, sys, time
from pathlib import Path
root=Path.cwd(); out=Path('/tmp/baz-extraction-macos-20260906'); original=subprocess.Popen; groups=[]
class TrackedPopen(original):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs)
        if kwargs.get('start_new_session'):
            groups.append(dict(pgid=self.pid,command=self.args,started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat()))
subprocess.Popen=TrackedPopen
error=None
try:
    sys.path.insert(0,str(root/'tests'))
    for suite in ('app_integration','examples_integration'):
        print('SUITE',suite,flush=True)
        sys.argv=[str(root/f'tests/{suite}.py')]
        try: runpy.run_path(sys.argv[0],run_name='__main__')
        except SystemExit as e:
            if e.code not in (None,0): raise
except BaseException as e:
    error=repr(e)
finally:
    for group in groups:
        try: os.killpg(group['pgid'],0); alive=True
        except ProcessLookupError: alive=False
        group['present_after_suite']=alive
        if alive:
            os.killpg(group['pgid'],signal.SIGTERM); deadline=time.monotonic()+8
            while time.monotonic()<deadline:
                try: os.killpg(group['pgid'],0)
                except ProcessLookupError: alive=False;break
                time.sleep(.05)
            if alive: os.killpg(group['pgid'],signal.SIGKILL)
        group['cleanup_was_needed']=group['present_after_suite']
    report=dict(error=error,groups=groups,finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
    (out/'baz-wire-child-groups.json').write_text(json.dumps(report,indent=2)+'\n')
    print('CHILD GROUPS',len(groups),'all absent',all(not g['present_after_suite'] for g in groups),flush=True)
if error or any(g['present_after_suite'] for g in groups): raise SystemExit(1)
