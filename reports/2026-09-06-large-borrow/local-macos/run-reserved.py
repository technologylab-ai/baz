import datetime,json,os,pathlib,signal,socket,subprocess,sys,time,uuid
root=pathlib.Path.cwd();lock=pathlib.Path('/tmp/zig-http-measurement.lock')
ps=subprocess.check_output(['ps','-axo','pid,ppid,pgid,command'],text=True)
conflicts=[s for s in ps.splitlines() if any(x in s for x in ['zig build','wrk -','--headless=new','integration.py','smoke.py']) and not any(x in s for x in ['run-reserved.py','/bin/zsh -lc',' rg '])]
if conflicts: print('Pre-existing workload; holding off:',conflicts);sys.exit(2)
try:lock.mkdir()
except FileExistsError:print('Host busy:',(lock/'owner.json').read_text() if (lock/'owner.json').exists() else 'metadata unavailable');sys.exit(2)
token=str(uuid.uuid4());owner={'agent':'baz large borrow /root','purpose':sys.argv[1],'host':socket.gethostname(),'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'owner_pid':os.getpid(),'token':token,'cwd':str(root)}
(lock/'owner.json').write_text(json.dumps(owner,indent=2)+'\n')
out=root/'.zig-cache/borrow-evidence';out.mkdir(exist_ok=True);log=out/(sys.argv[1]+'.log');proc=None;code=1
try:
 print('Reserved',socket.gethostname(),sys.argv[1],flush=True)
 with log.open('wb') as f:
  proc=subprocess.Popen(sys.argv[3:],cwd=sys.argv[2],stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  try:code=proc.wait(timeout=900)
  except subprocess.TimeoutExpired: print('Watchdog expired',flush=True)
finally:
 if proc:
  if proc.poll() is None:
   os.killpg(proc.pid,signal.SIGTERM)
   try:proc.wait(timeout=5)
   except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=5)
  def alive():
   try:os.killpg(proc.pid,0);return True
   except ProcessLookupError:return False
  if alive():
   os.killpg(proc.pid,signal.SIGTERM);end=time.monotonic()+5
   while alive() and time.monotonic()<end:time.sleep(.05)
   if alive():os.killpg(proc.pid,signal.SIGKILL)
   end=time.monotonic()+5
   while alive() and time.monotonic()<end:time.sleep(.05)
   if alive():raise RuntimeError('Owned child group remains')
 owner['exit_code']=code;owner['owned_group_absent']=proc.pid if proc else None
 (out/(sys.argv[1]+'-cleanup.json')).write_text(json.dumps(owner,indent=2)+'\n')
 if json.loads((lock/'owner.json').read_text())['token']!=token:raise RuntimeError('Lock owner changed')
 (lock/'owner.json').unlink();lock.rmdir()
 print('Released reservation; exit',code,flush=True)
 print('\n'.join(log.read_text(errors='replace').splitlines()[-(80 if code else 8):]))
sys.exit(code)
