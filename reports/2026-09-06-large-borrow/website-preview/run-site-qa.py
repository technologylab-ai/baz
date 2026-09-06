import datetime, functools, http.server, json, os, pathlib, signal, socket, subprocess, sys, threading, time, uuid
root=pathlib.Path.cwd()
lock=pathlib.Path('/tmp/zig-http-measurement.lock')
processes=subprocess.check_output(['ps','-axo','pid,ppid,pgid,command'],text=True)
conflicts=[line for line in processes.splitlines() if any(x in line for x in ['zig build','wrk -','--headless=new','tests/app_integration.py']) and not any(x in line for x in ['run-site-qa.py','rg ','/bin/zsh -lc'])]
if conflicts:
 print('Pre-existing workload; holding off:', '\n'.join(conflicts));sys.exit(2)
try:lock.mkdir()
except FileExistsError:
 print('Host busy:', (lock/'owner.json').read_text() if (lock/'owner.json').exists() else 'metadata unavailable');sys.exit(2)
token=str(uuid.uuid4())
owner={'agent':'baz-website /root','purpose':'finite static website browser checks only; no HTTP engine workload','host':socket.gethostname(),'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'owner_pid':os.getpid(),'token':token,'cwd':str(root)}
(lock/'owner.json').write_text(json.dumps(owner,indent=2)+'\n')
out=root/'.zig-cache/website-qa'/sys.argv[1]
out.mkdir(parents=True,exist_ok=True)
preview=root/'.zig-cache/preview';preview.mkdir(exist_ok=True)
link=preview/'baz'
if not link.exists():link.symlink_to(root/'.zig-cache/github-pages',target_is_directory=True)
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*args):pass
server=None;proc=None;groups=[]
def exists(pgid):
 try:os.killpg(pgid,0);return True
 except ProcessLookupError:return False
def cleanup(pgid):
 if not exists(pgid):return
 try:os.killpg(pgid,signal.SIGTERM)
 except ProcessLookupError:return
 end=time.monotonic()+5
 while exists(pgid) and time.monotonic()<end:time.sleep(.1)
 if exists(pgid):
  os.killpg(pgid,signal.SIGKILL)
  end=time.monotonic()+5
  while exists(pgid) and time.monotonic()<end:time.sleep(.1)
 if exists(pgid):raise RuntimeError('Owned process group remains: '+str(pgid))
try:
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=str(preview)))
 thread=threading.Thread(target=server.serve_forever);thread.start()
 url=sys.argv[2] if len(sys.argv)>2 else 'http://127.0.0.1:'+str(server.server_port)+'/baz/'
 print('Preview',url,flush=True)
 proc=subprocess.Popen(['node',os.environ.get('BAZ_SITE_CHECK','tools/check_site_browser.mjs'),url,str(out)],start_new_session=True)
 groups.append(proc.pid)
 try:rc=proc.wait(timeout=180)
 except subprocess.TimeoutExpired:
  os.killpg(proc.pid,signal.SIGTERM)
  try:proc.wait(timeout=10)
  except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=5)
  raise
finally:
 if proc and proc.poll() is None:
  os.killpg(proc.pid,signal.SIGTERM)
  try:proc.wait(timeout=10)
  except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=5)
 if (out/'browser-pid').exists():groups.append(int((out/'browser-pid').read_text()))
 for pgid in groups:cleanup(pgid)
 if server:server.shutdown();server.server_close();thread.join(timeout=5)
 receipt={'owner':owner,'owned_groups_absent':groups,'finished_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
 (out/'cleanup.json').write_text(json.dumps(receipt,indent=2)+'\n')
 if json.loads((lock/'owner.json').read_text())['token']!=token:raise RuntimeError('Lock ownership changed')
 (lock/'owner.json').unlink();lock.rmdir()
 print('Owned browser/server stopped; host reservation released.',flush=True)
sys.exit(rc)
