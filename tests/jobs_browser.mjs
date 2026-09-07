// Optional native Chrome application gate. The caller owns the ReleaseSafe server and host reservation.
// Start the fixture with --tick-ms 1200. Its job exceeds the fixed ten-second request deadline.
// Usage: node tests/jobs_browser.mjs http://127.0.0.1:PORT/ OUTPUT_DIRECTORY
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';

const [baseArgument, outputArgument] = process.argv.slice(2);
if (!baseArgument || !outputArgument) throw new Error('Provide the running jobs URL and an output directory.');
const base = new URL(baseArgument);
if (base.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(base.hostname))
  throw new Error('Use the reserved local ReleaseSafe jobs server.');
const output = path.resolve(outputArgument);
const executable = process.env.BROWSER || (process.platform === 'darwin'
  ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : '/usr/bin/chromium');
const cases = [], exceptions = [], events = [], requests = [], eventRequests = [], extraHeaders = new Map(), pending = new Map();
let browser, socket, session, sequence = 0, version;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(fn, description, timeout = 12000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try { if (await fn()) return; } catch (_) { /* Navigation replaces the execution context. */ }
    await delay(50);
  }
  throw new Error(description);
}
function send(method, params = {}, target = session) {
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('CDP timeout: ' + method)); }, 8000);
    pending.set(id, {resolve, reject, timer});
    socket.send(JSON.stringify({id, method, params, ...(target ? {sessionId: target} : {})}));
  });
}
async function evaluate(expression) {
  const value = await send('Runtime.evaluate', {expression, returnByValue: true, awaitPromise: true});
  if (value.exceptionDetails) throw new Error(JSON.stringify(value.exceptionDetails));
  return value.result.value;
}
async function click(selector) {
  const point = await evaluate(`(() => {
    const element = document.querySelector(${JSON.stringify(selector)});
    element.scrollIntoView({block:'center',behavior:'instant'});
    const rect = element.getBoundingClientRect();
    return {x:rect.x+rect.width/2,y:rect.y+rect.height/2};
  })()`);
  await send('Input.dispatchMouseEvent', {type:'mousePressed',button:'left',clickCount:1,...point});
  await send('Input.dispatchMouseEvent', {type:'mouseReleased',button:'left',clickCount:1,...point});
}
async function screenshot(name) {
  await evaluate('scrollTo(0,0)');
  const image = await send('Page.captureScreenshot', {format:'png',captureBeyondViewport:false});
  await writeFile(path.join(output, name + '.png'), Buffer.from(image.data, 'base64'));
}
async function noOverflow() {
  const state = await evaluate('({width:document.documentElement.clientWidth,content:document.documentElement.scrollWidth})');
  assert(state.content <= state.width + 1, JSON.stringify(state));
  return state;
}
async function check(name, task) {
  try {
    const evidence = await task();
    cases.push({name,ok:true,evidence});
    console.log('PASS ' + name);
  } catch (error) {
    cases.push({name,ok:false,error:error.message});
    await screenshot('failure-' + name).catch(() => {});
    throw error;
  }
}
function stopBrowser() {
  if (browser?.pid) { try { process.kill(-browser.pid, 'SIGTERM'); } catch (_) {} }
}
for (const signal of ['SIGTERM','SIGINT']) process.once(signal, () => { stopBrowser(); process.exit(130); });

try {
  await mkdir(output, {recursive:true});
  browser = spawn(executable, ['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check',
    '--disable-background-networking','--remote-debugging-port=0',
    '--user-data-dir=' + path.join(output,'profile'),'about:blank'],
  {detached:true,stdio:['ignore','ignore','pipe']});
  if (browser.pid) await writeFile(path.join(output,'browser-pid'), String(browser.pid));
  let diagnostics = '', spawnError;
  browser.on('error', error => { spawnError = error; });
  browser.stderr.on('data', data => { diagnostics = (diagnostics + data).slice(-65536); });
  await until(() => !spawnError && /DevTools listening on (ws:\/\/\S+)/.test(diagnostics),
    'Browser startup failed', 12000);
  if (spawnError) throw spawnError;
  socket = new WebSocket(diagnostics.match(/DevTools listening on (ws:\/\/\S+)/)[1]);
  await new Promise((resolve,reject) => {
    const timer = setTimeout(() => reject(new Error('Browser websocket timeout')), 8000);
    socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, {once:true});
    socket.addEventListener('error', error => { clearTimeout(timer); reject(error); }, {once:true});
  });
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data), job = pending.get(message.id);
    if (message.method === 'Runtime.exceptionThrown') exceptions.push(message.params.exceptionDetails);
    if (message.method === 'Network.eventSourceMessageReceived') {
      const {eventName,eventId,data} = message.params;
      if (events.length < 128) events.push({eventName,eventId,data});
      else exceptions.push({error:'Browser event evidence exceeded its bound'});
    }
    if (message.method === 'Network.requestWillBeSentExtraInfo') {
      const {requestId,headers} = message.params;
      const header = Object.entries(headers).find(([name]) => name.toLowerCase() === 'last-event-id');
      if (header) {
        if (extraHeaders.size < 256) extraHeaders.set(requestId,header[1]);
        for (const request of eventRequests)
          if (request.requestId === requestId) request.lastEventId = header[1];
      }
    }
    if (message.method === 'Network.requestWillBeSent' && requests.length < 256) {
      const request = message.params.request;
      requests.push(request.url);
      if (/\/jobs\/[0-9]+-[0-9]+\/events$/.test(request.url)) {
        const header = Object.entries(request.headers).find(([name]) => name.toLowerCase() === 'last-event-id');
        eventRequests.push({requestId:message.params.requestId,url:request.url,
          lastEventId:header?.[1] ?? extraHeaders.get(message.params.requestId) ?? null});
      }
    }
    if (!job) return;
    clearTimeout(job.timer); pending.delete(message.id);
    if (message.error) job.reject(new Error(JSON.stringify(message.error))); else job.resolve(message.result);
  });
  const target = await send('Target.createTarget', {url:'about:blank'}, null);
  session = (await send('Target.attachToTarget',{targetId:target.targetId,flatten:true},null)).sessionId;
  await send('Page.enable'); await send('Runtime.enable'); await send('Network.enable');
  await send('Network.setCacheDisabled',{cacheDisabled:true});
  version = await send('Browser.getVersion', {}, null);

  for (const width of [1440,390,320]) {
    await send('Emulation.setDeviceMetricsOverride',{width,height:1000,deviceScaleFactor:1,mobile:false});
    await check('login-' + width, async () => {
      for (let attempt = 0; attempt < 10; attempt++) {
        await send('Page.navigate',{url:new URL('/login',base).href});
        await until(() => evaluate('document.readyState === "complete" && !!document.querySelector("input[name=username]")'),
          'Login form failed to load');
        await noOverflow(); await screenshot('jobs-login-' + width);
        assert.equal(await evaluate('document.querySelector("input[name=username]").value'),'zap');
        assert.equal(await evaluate('document.querySelector("input[name=password]").value'),'awesome');
        await click('form button');
        await until(() => evaluate('!!document.querySelector("#start") || document.body.textContent.trim() === "Application state is busy"'),
          'Login did not reach the protected application');
        if (await evaluate('!!document.querySelector("#start")')) break;
        if (attempt === 9) throw new Error('Login contention retry budget exhausted');
        await delay(50);
      }
      assert.equal(await evaluate('document.querySelector(".username").textContent'),'zap');
      assert.equal(await evaluate('document.body.textContent.includes("{{username}}")'),false);
      const cookies = (await send('Network.getCookies',{urls:[base.href]})).cookies;
      const sessionCookie = cookies.find(cookie => cookie.name === 'baz-jobs-session');
      assert(sessionCookie?.httpOnly && sessionCookie.session && sessionCookie.sameSite === 'Strict');
      assert.equal(await evaluate('document.cookie.includes("baz-jobs-session")'),false);
      await noOverflow();
      return {width,renderedIdentity:'zap',httpOnly:true,sessionCookie:true};
    });
    await check('native-event-source-' + width, async () => {
      const firstEvent = events.length;
      for (let attempt = 0; attempt < 10; attempt++) {
        await click('#start');
        await until(() => evaluate('!!document.querySelector("article.job") || document.querySelector("#notice").textContent.length > 0'),
          'Start job did not create a card');
        if (await evaluate('!!document.querySelector("article.job")')) break;
        assert.equal(await evaluate('document.querySelector("#notice").textContent'),'Application state is busy');
        if (attempt === 9) throw new Error('Create-job contention retry budget exhausted');
        await delay(50);
      }
      let reconnect = null;
      if (width === 1440) {
        await until(() => events.length > firstEvent, 'Native EventSource did not deliver its initial event');
        const acknowledged = events.at(-1).eventId;
        const firstRequest = eventRequests.length;
        // The real server deadline closes this response before the twelve-second job ends.
        // Native EventSource must reconnect and carry its acknowledged cursor automatically.
        await until(() => eventRequests.slice(firstRequest).some(request => request.lastEventId !== null),
          'Native EventSource did not reconnect after the request deadline with Last-Event-ID', 20000);
        reconnect = {trigger:'request deadline',acknowledged,requests:eventRequests.slice(firstRequest)};
        assert(reconnect.requests.some(request => Number(request.lastEventId) >= Number(acknowledged)));
      }
      await until(() => evaluate('document.querySelector("article.job .tag")?.textContent === "Complete"'),
        'Browser EventSource did not deliver job completion', 20000);
      assert.equal(await evaluate('document.querySelector("article.job h2").textContent'),'100%');
      assert.equal(await evaluate('document.querySelector("article.job progress").value'),100);
      const received = events.slice(firstEvent);
      assert.deepEqual(received.map(event => Number(event.eventId)),Array.from({length:11},(_,index) => index+1));
      assert.equal(received.at(-1).eventName,'done');
      assert.equal(JSON.parse(received.at(-1).data).done,true);
      await noOverflow(); await screenshot('jobs-complete-' + width);
      return {width,nativeEvents:received.length,ids:received.map(event => event.eventId),reconnect};
    });
    await check('logout-' + width, async () => {
      await click('form[action="/logout"] button');
      await until(() => evaluate('location.pathname === "/login" && !!document.querySelector("input[name=username]")'),
        'Logout did not return to sign-in');
      const cookies = (await send('Network.getCookies',{urls:[base.href]})).cookies;
      assert.equal(cookies.some(cookie => cookie.name === 'baz-jobs-session'),false);
      return {cookieDeleted:true};
    });
  }
  await check('no-script-errors-or-external-requests', async () => {
    assert.deepEqual(exceptions,[]);
    assert.deepEqual(requests.filter(url => url.startsWith('http') && !url.startsWith(base.origin + '/')),[]);
    return {requests:requests.length,exceptions:0};
  });
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  await writeFile(path.join(output,'receipt.json'),JSON.stringify({base:base.href,browser:version?.product,cases,exceptions,events,eventRequests},null,2)+'\n').catch(() => {});
  if (socket?.readyState === WebSocket.OPEN) {
    await send('Browser.close',{},null).catch(() => {}); socket.close();
  }
  stopBrowser();
  if (browser?.pid) {
    const gone = () => { try { process.kill(-browser.pid,0); return false; } catch (error) { if (error.code === 'ESRCH') return true; throw error; } };
    try { await until(gone,'Browser process group did not stop',5000); }
    catch (_) { try { process.kill(-browser.pid,'SIGKILL'); } catch (_) {} await until(gone,'Browser cleanup failed',5000); }
  }
  for (const job of pending.values()) clearTimeout(job.timer);
}
