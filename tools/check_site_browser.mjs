// Optional browser smoke checks. Acquire the shared host reservation before use.
// Usage: node tools/check_site_browser.mjs BASE_URL OUTPUT_DIRECTORY
// BROWSER can select an installed Chromium or Chrome executable.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, writeFile, readFile} from 'node:fs/promises';
import path from 'node:path';

const [baseArgument, outputArgument] = process.argv.slice(2);
if (!baseArgument || !outputArgument) throw new Error('Provide the site URL and an output directory.');
const base = new URL(baseArgument);
if (!['http:', 'https:'].includes(base.protocol)) throw new Error('Serve the artifact over HTTP.');
const output = path.resolve(outputArgument);
const executable = process.env.BROWSER || (process.platform === 'darwin'
  ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : '/usr/bin/chromium');
const cases = [];
const exceptions = [];
const requests = [];
const logs = [];
const expectedCspBlocks = new Set();
const pending = new Map();
let browser, socket, session, sequence = 0;
let interceptedBody = null;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(fn, description, timeout = 15000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try { if (await fn()) return; } catch (_) { /* Navigation can replace a JavaScript context. */ }
    await delay(50);
  }
  throw new Error(description);
}
function send(method, params = {}, target = session) {
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('CDP timeout: ' + method)); }, 10000);
    pending.set(id, {resolve, reject, timer});
    socket.send(JSON.stringify({id, method, params, ...(target ? {sessionId: target} : {})}));
  });
}
async function evaluate(expression) {
  const result = await send('Runtime.evaluate', {expression, returnByValue: true, awaitPromise: true});
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
async function navigate(query = '', kind = 'paper') {
  await send('Page.navigate', {url: 'about:blank'});
  await until(() => evaluate('location.href === "about:blank"'), 'Blank navigation failed');
  await send('Page.navigate', {url: new URL(query, base).href});
  const expression = kind === 'reader'
    ? '["true","error"].includes(document.documentElement.dataset.readerReady)'
    : 'document.readyState === "complete" && !!document.querySelector(".hero")';
  await until(() => evaluate(expression), 'Page failed to load');
}
async function screenshot(name) {
  const shot = await send('Page.captureScreenshot', {format: 'png', captureBeyondViewport: false});
  await writeFile(path.join(output, name + '.png'), Buffer.from(shot.data, 'base64'));
}
async function check(name, fn) {
  try {
    const evidence = await fn();
    cases.push({name, ok: true, evidence});
    console.log('PASS ' + name);
  } catch (error) {
    cases.push({name, ok: false, error: error.message});
    console.log('FAIL ' + name + ': ' + error.message);
    await screenshot('failure-' + name).catch(() => {});
  }
}
function stopBrowser() {
  if (browser?.pid) {
    try { process.kill(-browser.pid, 'SIGTERM'); } catch (_) {}
  }
}
for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, () => { stopBrowser(); process.exit(130); });

try {
  await mkdir(output, {recursive: true});
  browser = spawn(executable, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--disable-background-networking', '--remote-debugging-port=0', '--user-data-dir=' + path.join(output, 'profile'), 'about:blank'],
  {detached: true, stdio: ['ignore', 'ignore', 'pipe']});
  if (browser.pid) await writeFile(path.join(output, 'browser-pid'), String(browser.pid));
  let diagnostics = '', spawnError;
  browser.on('error', error => { spawnError = error; });
  browser.stderr.on('data', chunk => { diagnostics += chunk.toString(); });
  await until(() => { if (spawnError) throw spawnError; return /DevTools listening on (ws:\/\/\S+)/.test(diagnostics); }, 'Browser did not start');
  socket = new WebSocket(diagnostics.match(/DevTools listening on (ws:\/\/\S+)/)[1]);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, {once: true});
    socket.addEventListener('error', reject, {once: true});
  });
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data), job = pending.get(message.id);
    if (message.method === 'Fetch.requestPaused') {
      const requestId = message.params.requestId;
      const operation = interceptedBody === null ? send('Fetch.continueRequest', {requestId}) : send('Fetch.fulfillRequest', {requestId, responseCode: 200, responseHeaders: [{name: 'Content-Type', value: 'text/plain; charset=utf-8'}], body: Buffer.from(interceptedBody).toString('base64')});
      operation.catch(error => exceptions.push({interception: error.message}));
    }
    if (message.method === 'Runtime.exceptionThrown') exceptions.push(message.params.exceptionDetails);
    if (message.method === 'Network.requestWillBeSent') requests.push(message.params.request.url);
    if (message.method === 'Log.entryAdded') logs.push(message.params.entry);
    if (!job) return;
    clearTimeout(job.timer); pending.delete(message.id);
    if (message.error) job.reject(new Error(JSON.stringify(message.error))); else job.resolve(message.result);
  });
  const target = await send('Target.createTarget', {url: 'about:blank'}, null);
  session = (await send('Target.attachToTarget', {targetId: target.targetId, flatten: true}, null)).sessionId;
  await send('Page.enable'); await send('Runtime.enable'); await send('Network.enable'); await send('Log.enable');
  await send('Network.setCacheDisabled',{cacheDisabled:true});
  const version = await send('Browser.getVersion', {}, null);
  await send('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'no-preference'}]});
  await send('Emulation.setDeviceMetricsOverride', {width: 1440, height: 1040, deviceScaleFactor: 1, mobile: false});



  async function click(selector) {
    const point = await evaluate(`(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; })()`);
    await send('Input.dispatchMouseEvent', {type:'mousePressed',button:'left',clickCount:1,...point});
    await send('Input.dispatchMouseEvent', {type:'mouseReleased',button:'left',clickCount:1,...point});
  }
  async function key(key) {
    await send('Input.dispatchKeyEvent',{type:'keyDown',key,code:key,windowsVirtualKeyCode:key==='Tab'?9:27});
    await send('Input.dispatchKeyEvent',{type:'keyUp',key,code:key,windowsVirtualKeyCode:key==='Tab'?9:27});
  }
  async function noOverflow() {
    const state = await evaluate('({width:document.documentElement.clientWidth,content:document.documentElement.scrollWidth})');
    assert(state.content <= state.width + 1, JSON.stringify(state)); return state;
  }
  await check('desktop-landing', async () => {
    await navigate();
    const state = await evaluate(`({title:document.title,headline:document.querySelector('h1').textContent,diagrams:document.querySelectorAll('svg[role="img"]').length,examples:document.querySelectorAll('.example-card').length,highlight:!!document.querySelector('.hljs-keyword')})`);
    assert.equal(state.title,'Baz — Bounded Async Zap'); assert.equal(state.diagrams,4); assert.equal(state.examples,22); assert(state.highlight);
    await noOverflow(); await screenshot('baz-desktop'); return state;
  });
  await check('maintained-source-excerpt', async () => {
    const source = await readFile(new URL('../src/app_demo.zig', import.meta.url),'utf8');
    const excerpt = source.match(/^const Hello = struct \{\n[\s\S]*?^\};/m)[0];
    assert.equal(await evaluate('document.querySelector(".language-zig").textContent'),excerpt); return {exactSource:true};
  });
  await check('streaming-example-source-tabs-and-deep-link', async () => {
    const source = await readFile(new URL('../examples/streaming.zig', import.meta.url), 'utf8');
    const excerpt = source.match(/^fn progress\(.*?^}/ms)[0];
    assert.equal(await evaluate('document.querySelector("#streaming code.language-zig").textContent'), excerpt);
    assert(await evaluate('document.querySelector("#streaming").hidden'));
    await evaluate('document.querySelector("#streaming-tab").scrollIntoView({behavior:"instant",block:"start"})');
    await click('#streaming-tab');
    assert.equal(await evaluate('document.querySelector("#streaming-tab").getAttribute("aria-selected")'), 'true');
    assert(await evaluate('document.querySelector("#app-example").hidden && !document.querySelector("#streaming").hidden'));
    await noOverflow(); await screenshot('baz-streaming-desktop');
    await key('Home');
    assert.equal(await evaluate('document.activeElement.id'), 'basics-tab');
    assert(await evaluate('document.querySelector("#streaming").hidden'));
    await key('ArrowRight');
    assert.equal(await evaluate('document.activeElement.id'), 'streaming-tab');
    for (const width of [390, 320]) {
      await send('Emulation.setDeviceMetricsOverride', {width,height:1040,deviceScaleFactor:1,mobile:false});
      await navigate('#streaming');
      assert(await evaluate('!document.querySelector("#streaming").hidden'));
      await noOverflow(); await screenshot('baz-streaming-' + width);
    }
    await send('Emulation.setDeviceMetricsOverride', {width:1440,height:1040,deviceScaleFactor:1,mobile:false});
    return {exactSource:true, keyboard:true, deepLink:true, mobileWidths:[390,320]};
  });
  await check('borrowed-example-source-tabs-and-deep-link', async () => {
    const source = await readFile(new URL('../examples/serve.zig', import.meta.url), 'utf8');
    const excerpt = source.match(/^const Shared = struct \{\};\n.*?^fn index\(.*?^}/ms)[0];
    await navigate();
    assert.equal(await evaluate('document.querySelectorAll(".example-tabs [role=tab]").length'), 3);
    assert.equal(await evaluate('document.querySelector("#borrowed code.language-zig").textContent'), excerpt);
    await evaluate('document.querySelector("#borrowed-tab").scrollIntoView({behavior:"instant",block:"start"})');
    await click('#borrowed-tab');
    assert(await evaluate('!document.querySelector("#borrowed").hidden && document.querySelector("#streaming").hidden && document.querySelector("#app-example").hidden'));
    await noOverflow(); await screenshot('baz-borrowed-desktop');
    await key('ArrowRight');
    assert.equal(await evaluate('document.activeElement.id'), 'basics-tab');
    await key('End');
    assert.equal(await evaluate('document.activeElement.id'), 'borrowed-tab');
    await key('ArrowLeft');
    assert.equal(await evaluate('document.activeElement.id'), 'streaming-tab');
    for (const width of [390, 320]) {
      await send('Emulation.setDeviceMetricsOverride', {width,height:1040,deviceScaleFactor:1,mobile:false});
      await navigate('#borrowed');
      assert(await evaluate('!document.querySelector("#borrowed").hidden'));
      await noOverflow(); await screenshot('baz-borrowed-' + width);
    }
    await send('Emulation.setDeviceMetricsOverride', {width:1440,height:1040,deviceScaleFactor:1,mobile:false});
    await evaluate('document.querySelector("#basics-tab").scrollIntoView({behavior:"instant",block:"start"})');
    await click('#basics-tab');
    await click('a[href="#borrowed"]');
    assert(await evaluate('!document.querySelector("#borrowed").hidden'));
    return {exactSource:true, keyboard:true, deepLink:true, repeatedDeepLink:true, mobileWidths:[390,320]};
  });
  await check('keyboard-skip-link', async () => {
    await navigate(); await key('Tab');
    assert.equal(await evaluate('document.activeElement.className'),'skip');
    await send('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});
    await send('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});
    assert.equal(await evaluate('document.activeElement.id'),'main'); return {skipFocus:'main'};
  });
  await check('example-filters', async () => {
    await evaluate('document.querySelector("#examples").scrollIntoView({behavior:"instant"})');
    for (const [group,count] of [['data',2],['composition',6],['app',3],['routing',5],['responses',6],['all',22]]) {
      await click(`button[data-filter="${group}"]`);
      assert.equal(await evaluate('document.querySelectorAll(".example-card:not([hidden])").length'),count);
      assert.equal(await evaluate('document.querySelector("#example-count").textContent'),`${count} of 22 examples`);
    }
    return {groups:6,total:22};
  });
  await check('desktop-diagrams-and-benchmark', async () => {
    await evaluate('document.querySelector("#engine").scrollIntoView({behavior:"instant"})'); await screenshot('baz-engine');
    await evaluate('document.querySelector("#performance").scrollIntoView({behavior:"instant"})'); await screenshot('baz-performance');
    const rows = await evaluate('Array.from(document.querySelectorAll(".benchmark-table tbody tr"),row=>row.innerText)');
    assert.equal(rows.length,4); assert(rows.some(row=>row.includes('0.629×'))); return {rows};
  });
  await check('mobile-navigation-and-layout', async () => {
    await send('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:false}); await navigate();
    await noOverflow(); await screenshot('baz-mobile');
    await click('.mobile-menu'); assert.equal(await evaluate('document.querySelector(".mobile-menu").getAttribute("aria-expanded")'),'true');
    await key('Escape'); assert.equal(await evaluate('document.querySelector(".mobile-menu").getAttribute("aria-expanded")'),'false');
    await click('.mobile-menu'); await click('#navigation a[href="#examples"]');
    assert.equal(await evaluate('document.querySelector(".mobile-menu").getAttribute("aria-expanded")'),'false');
    await until(()=>evaluate('location.hash === "#examples"'),'Section navigation did not update hash');
    await evaluate('document.querySelector("#data").scrollIntoView({behavior:"instant"})'); await screenshot('baz-mobile-data');
    for (const width of [320,760,820,1024,1440]) {
      await send('Emulation.setDeviceMetricsOverride',{width,height:1000,deviceScaleFactor:1,mobile:false}); await noOverflow();
    }
    return {widths:[320,390,760,820,1024,1440],menu:'open / Escape / section link'};
  });
  await check('reader-guide-and-fragment', async () => {
    await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1040,deviceScaleFactor:1,mobile:false});
    await navigate('docs/read.html?file=docs/APP-API.md#borrowed-request-bytes','reader');
    assert.equal(await evaluate('document.documentElement.dataset.readerReady'),'true');
    assert(await evaluate('document.querySelectorAll("#contents a").length > 5'));
    assert(await evaluate('!!document.querySelector("#document .hljs-keyword")'));
    const fragment = await evaluate('document.querySelector("#borrowed-request-bytes").getBoundingClientRect().top');
    assert(fragment>=0 && fragment<200);
    await screenshot('baz-reader'); await noOverflow(); return {fragmentTop:fragment};
  });
  await check('mustache-preview-and-source', async () => {
    await navigate('docs/read.html?file=docs/MUSTACHE.md#rendered-example','reader');
    await until(() => evaluate('Array.from(document.querySelectorAll("#document img")).some(img => img.complete && img.naturalWidth > 0 && img.src.endsWith("/docs/assets/mustache-preview.png"))'), 'Mustache preview did not load');
    assert(await evaluate('Array.from(document.querySelectorAll("#document a")).some(a => new URL(a.href).searchParams.get("file") === "examples/mustache.zig")'));
    await noOverflow(); await screenshot('baz-mustache-guide');
    await send('Emulation.setDeviceMetricsOverride',{width:320,height:844,deviceScaleFactor:1,mobile:false});
    await noOverflow(); await screenshot('baz-mustache-guide-mobile');
    await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1040,deviceScaleFactor:1,mobile:false});
    return {previewLoaded:true, sourceLinked:true, narrowWidth:320};
  });
  await check('reader-source-and-links', async () => {
    await navigate('docs/read.html?file=examples/app_basic.zig','reader');
    assert.equal(await evaluate('document.querySelector("h1").textContent'),'app_basic.zig');
    assert(await evaluate('!!document.querySelector(".hljs-keyword")'));
    const links = await evaluate('({raw:document.querySelector("#raw").href,source:document.querySelector("#source").href})');
    assert(links.raw.startsWith(base.href)); assert(links.source.startsWith('https://github.com/technologylab-ai/baz/blob/')); return links;
  });
  await check('reader-mobile', async () => {
    await send('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:false});
    await navigate('docs/read.html?file=docs/APP-API.md','reader'); await noOverflow(); await screenshot('baz-reader-mobile');
    await click('.mobile-menu'); assert(await evaluate('document.querySelector("#contents").getBoundingClientRect().width > 0'));
    await key('Escape'); return {width:390};
  });
  await check('reader-rejects-unpublished-paths', async () => {
    for (const file of ['../README.md','/README.md','docs/../README.md','https://example.com/README.md','docs/%2e%2e/README.md','missing.md']) {
      const before = requests.length;
      await navigate('docs/read.html?file='+encodeURIComponent(file),'reader');
      assert.equal(await evaluate('document.documentElement.dataset.readerReady'),'error');
      assert.equal(await evaluate('document.querySelector("#document").children.length'),0);
      assert(!requests.slice(before).some(url=>url.endsWith('/README.md') || url.endsWith('/missing.md')));
    }
    return {rejected:6};
  });

  await check('reader-sanitizes-markdown-before-insertion', async () => {
    const firstLog = logs.length;
    interceptedBody = '# Safe heading\n\n<script>window.readerInjection = true</script><img src="https://invalid.example/track" onerror="window.readerInjection=true"><a href="javascript:window.readerInjection=true">bad link</a><iframe src="https://invalid.example/frame"></iframe><form id="document"><input name="location"></form><div style="position:fixed" id="status">Untrusted text</div>\n\n## A section\n\n[Local guide](docs/OWNERSHIP.md)\n\n```zig\nconst x = 1;\n```';
    await send('Fetch.enable',{patterns:[{urlPattern:new URL('README.md',base).href,requestStage:'Request'}]});
    try {
      await navigate('docs/read.html?file=README.md','reader');
      assert.equal(await evaluate('document.documentElement.dataset.readerReady'),'true');
      const state=await evaluate(`({injected:window.readerInjection===true,unsafe:document.querySelectorAll('#document script,#document img,#document iframe,#document form,#document input,#document [style],#document [onerror],#document a[href^="javascript:"]').length,heading:document.querySelector('#document h1').id,local:Array.from(document.querySelectorAll('#document a')).find(a=>a.textContent==='Local guide').href})`);
      assert.equal(state.injected,false); assert.equal(state.unsafe,0); assert.equal(state.heading,'safe-heading');
      assert(state.local.includes('docs/read.html?file=docs%2FOWNERSHIP.md'));
      for (const entry of logs.slice(firstLog)) {
        assert(entry.source === 'security' && entry.text.startsWith('Applying inline style violates') && entry.text.includes('The action has been blocked.'));
        expectedCspBlocks.add(entry);
      }
      return {...state, expectedStyleBlocks: logs.length - firstLog};
    } finally { interceptedBody=null; await send('Fetch.disable'); }
  });

  await check('all-published-documents-render', async () => {
    await navigate('docs/read.html','reader');
    const files = await evaluate('window.DOC_SITE.documents');
    for (const file of files) {
      await navigate('docs/read.html?file='+encodeURIComponent(file),'reader');
      assert.equal(await evaluate('document.documentElement.dataset.readerReady'),'true',file);
      assert(await evaluate('document.querySelector("#document").textContent.length > 0'),file);
      await noOverflow();
    }
    return {documents:files.length};
  });
  await check('print-and-no-javascript', async () => {
    await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1040,deviceScaleFactor:1,mobile:false}); await navigate();
    await send('Emulation.setEmulatedMedia',{media:'print'});
    assert.equal(await evaluate('getComputedStyle(document.querySelector(".rail")).display'),'none');
    assert(await evaluate('[...document.querySelectorAll("[role=tabpanel]")].every(panel => getComputedStyle(panel).display !== "none")'));
    const pdf = await send('Page.printToPDF',{printBackground:true,preferCSSPageSize:true});
    await writeFile(path.join(output,'baz-print.pdf'),Buffer.from(pdf.data,'base64'));
    await send('Emulation.setEmulatedMedia',{media:''}); await send('Emulation.setScriptExecutionDisabled',{value:true});
    await navigate();
    assert.equal(await evaluate('document.querySelectorAll(".example-card:not([hidden])").length'),22);
    assert(await evaluate('document.querySelector(".language-zig").textContent.includes("percentDecodeInto")'));
    assert(await evaluate('[...document.querySelectorAll("[role=tabpanel]")].every(panel => !panel.hidden && getComputedStyle(panel).display !== "none")'));
    await send('Emulation.setScriptExecutionDisabled',{value:false}); return {printBytes:Buffer.from(pdf.data,'base64').length,noJsExamples:22};
  });
  await check('no-unexpected-network-or-errors', async () => {
    assert.equal(exceptions.length,0,JSON.stringify(exceptions));
    const external = requests.filter(url=>url.startsWith('http') && !url.startsWith(base.origin+'/'));
    assert.deepEqual(external,[]);
    const errors=logs.filter(entry=>entry.level==='error' && !expectedCspBlocks.has(entry)); assert.deepEqual(errors,[]);
    return {requests:requests.length,exceptions:0,external:0,expectedCspBlocks:expectedCspBlocks.size};
  });
  await writeFile(path.join(output,'receipt.json'), JSON.stringify({base:base.href,browser:version.product,cases,exceptions},null,2)+'\n');
  if (cases.some(test=>!test.ok) || exceptions.length) process.exitCode=1;
} finally {
  if (socket?.readyState === WebSocket.OPEN) {
    await send('Browser.close', {}, null).catch(()=>{}); socket.close();
  }
  stopBrowser();
  if (browser?.pid) {
    const gone = () => { try { process.kill(-browser.pid, 0); return false; } catch (error) { if (error.code === 'ESRCH') return true; throw error; } };
    try { await until(gone, 'Browser process group did not stop', 5000); }
    catch (_) { try { process.kill(-browser.pid, 'SIGKILL'); } catch (_) {} await until(gone, 'Browser cleanup failed', 5000); }
  }
  for (const job of pending.values()) clearTimeout(job.timer);
}
