// 使い方: node bench.js <motion|reduce> <run> <trace:1|0> <outdir>
const L = require('./lib2'); const fs = require('fs'); const zlib = require('zlib');
const [COND, RUN, TRACE, OUTDIR] = [process.argv[2], process.argv[3], process.argv[4] === '1', process.argv[5]];
fs.mkdirSync(OUTDIR + '/traces', { recursive: true });
const sleep = L.sleep; const REC = process.env.REC === '1'; const RECDIR = OUTDIR + '/rec_' + COND + RUN;
const cred = JSON.parse(fs.readFileSync(require('os').homedir() + '/.linkday_verify/credentials.json', 'utf8'));
const CATS = (process.env.CATS_EXTRA?process.env.CATS_EXTRA.split(','):[]).concat(['devtools.timeline', 'disabled-by-default-devtools.timeline', 'disabled-by-default-devtools.timeline.frame', 'blink.user_timing', 'toplevel', 'gpu']);
const P = { card: { att: [195, 745], cust: [195, 205] }, back: [28, 28], dateBtn: [287, 28], day: d => [[28 + 47.7 * ((d - 1) % 7) + 24, 358 + 48 * Math.floor((d - 1) / 7) + 24]][0], ok: [338, 680] };
const dayPos = d => { // 11月: 1日=日曜。ダンプ値 (x:28+47.67*col, y:358+48*row) の中心
  const i = d - 1, col = i % 7, row = Math.floor(i / 7); return [28 + 47.67 * col + 24, 358 + 48 * row + 24]; };
async function tap(page, [x, y]) { await page.mouse.move(x, y); await sleep(120); await page.mouse.down(); await sleep(60); await page.mouse.up(); }
async function pageTitle(page) { return page.screenshot({ encoding: 'base64' }).then(s => s.length); }
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 390, height: 844 });
  const NETLOG=[]; page.on('request', r=>NETLOG.push([Date.now(), r.url().slice(0,400)])); page.on('response', r=>NETLOG.push([Date.now(), 'RESP '+r.status()+' cache='+r.fromCache()+' '+r.url().slice(-60)])); page.on('requestfinished', r=>NETLOG.push([Date.now(),'FIN '+r.url().slice(0,120)])); page.on('requestfailed', r=>NETLOG.push([Date.now(),'FAILED '+r.url().slice(0,120)]));
  const cdp = await page.createCDPSession();
  await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: COND === 'reduce' ? 'reduce' : 'no-preference' }] });
  await page.evaluateOnNewDocument(() => {
    window.__logs=[]; const _cl=console.log.bind(console); console.log=(...a)=>{window.__logs.push([performance.now(),a.join(' ').slice(0,200)]);_cl(...a)}; const _cd=console.debug.bind(console); window.__lt = []; window.__ev = []; window.__fm = [];
    try { new PerformanceObserver(l => l.getEntries().forEach(e => { if (['Frame','BUILD','LAYOUT (root)','PAINT (root)','COMPOSITING','SEMANTICS (root)','Animate','POST_FRAME'].includes(e.name)) window.__fm.push([e.name, e.startTime, e.duration]); })).observe({ type: 'measure', buffered: true }); } catch (_) {}
    try { new PerformanceObserver(l => l.getEntries().forEach(e => window.__lt.push([e.startTime, e.duration]))).observe({ type: 'longtask', buffered: true }); } catch (_) {}
    window.addEventListener('pointerup', e => { performance.mark('OP_START'); window.__ev.push(['up', e.timeStamp, performance.now()]); }, true);
    window.addEventListener('wheel', e => { performance.mark('WHEEL'); window.__ev.push(['wheel', e.timeStamp, performance.now()]); }, true);
  });
  await page.goto(L.BASE, { waitUntil: 'load' });
  await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 90000 }); await sleep(1500);
  const meta = { cond: COND, run: +RUN, trace: TRACE, mq: await page.evaluate(() => matchMedia('(prefers-reduced-motion: reduce)').matches),
    delay: await page.evaluate(() => localStorage.getItem('flutter.verify_delay_ms')), faults: await page.evaluate(() => localStorage.getItem('flutter.verify_faults')) };
  // ログイン（セマンティクスは有効化せず、座標で実マウス・実キーボード操作）
  await page.mouse.click(195, 424); await sleep(400); await page.keyboard.type(cred.email, { delay: 20 });
  await page.mouse.click(195, 520); await sleep(600); await page.keyboard.type(cred.password, { delay: 20 }); await page.keyboard.press('Enter');
  await sleep(5000);
  meta.semanticsNodes = await page.evaluate(() => document.querySelectorAll('flt-semantics').length);
  await page.screenshot({ path: `${OUTDIR}/${COND}${RUN}_home.png` });
  // ── ウォームアップ（計測外）: A → C(13日→15日) → 戻る → B
  const scrollRun = async (n, dy, interval) => { const t0 = Date.now(); await page.mouse.move(195, 500); for (let i = 0; i < n; i++) { const target = t0 + i * interval; const w = target - Date.now(); if (w > 0) await sleep(w); await page.mouse.wheel({ deltaY: dy }); } };
  await tap(page, P.card.att); await sleep(2500);
  await tap(page, P.dateBtn); await sleep(1200); await tap(page, dayPos(13)); await sleep(500); await tap(page, P.ok); await sleep(2000);
  await tap(page, P.dateBtn); await sleep(1200); await tap(page, dayPos(15)); await sleep(500); await tap(page, P.ok); await sleep(2000);
  await tap(page, P.back); await sleep(2000);
  await tap(page, P.card.cust); await sleep(2500);
  await scrollRun(30, 150, 66); await sleep(800); await scrollRun(30, -150, 66); await sleep(1500);
  await tap(page, P.back); await sleep(3000);
  // ── 計測
  const ops = [];
  async function traced(name, fn) {
    if (TRACE) { await page.tracing.start({ path: `${OUTDIR}/traces/${COND}${RUN}_${name}.json`, categories: CATS }); await sleep(500); }
    await page.evaluate(() => { window.__ev.length = 0; performance.clearMarks('OP_START'); performance.clearMarks('WHEEL'); });
    let rcdp, rframes = [];
    if (REC) { rcdp = await page.createCDPSession(); rcdp.on('Page.screencastFrame', f => { rframes.push([f.metadata.timestamp, f.data]); rcdp.send('Page.screencastFrameAck', { sessionId: f.sessionId }).catch(() => {}); }); await rcdp.send('Page.startScreencast', { format: 'jpeg', quality: 60, everyNthFrame: 1 }); await sleep(300); rframes.length = 0; }
    const tStart = Date.now() / 1000; NETLOG.push([Date.now(),'--- OP '+name+' START']);
    let pc; if (process.env.PROF && name==='A') { pc = await page.createCDPSession(); await pc.send('Profiler.enable'); await pc.send('Profiler.setSamplingInterval', { interval: 200 }); await pc.send('Profiler.start'); }
    await fn();
    if (pc) { const { profile } = await pc.send('Profiler.stop'); fs.writeFileSync(`${OUTDIR}/prof_${COND}${RUN}.json`, JSON.stringify(profile)); }
    if (REC) { await rcdp.send('Page.stopScreencast'); const dd = `${RECDIR}/${name}`; fs.mkdirSync(dd, { recursive: true }); fs.writeFileSync(`${dd}/ts.json`, JSON.stringify({ tStart, ts: rframes.map(f => f[0]) })); rframes.forEach((f, i) => fs.writeFileSync(`${dd}/f${String(i).padStart(4, '0')}.jpg`, Buffer.from(f[1], 'base64'))); await rcdp.detach(); }
    ops.push({ name, ev: await page.evaluate(() => window.__ev.slice()) });
    if (TRACE) await page.tracing.stop();
  }
  const shotBefore = async n => page.screenshot({ path: `${OUTDIR}/${COND}${RUN}_${n}.png` });
  // A: ホーム → 出席画面
  await traced('A', async () => { await tap(page, P.card.att); await sleep(3000); });
  await shotBefore('A_after');
  // アイドル観測: A の窓(3s)後、さらに 1s 待ってから IDLE_MS 操作せず観測
  await sleep(1000);
  const idleStart = await page.evaluate(() => performance.now());
  await sleep(+(process.env.IDLE_MS||6000));
  const idleEnd = await page.evaluate(() => performance.now());
  await shotBefore('idle_after');
  meta.idle = [idleStart, idleEnd];
  // 収集
  const raw = await page.evaluate(() => ({ res: performance.getEntriesByType('resource').filter(e=>/fonts\.gstatic|canvaskit/.test(e.name)).map(e=>[e.name.slice(-40), e.startTime, e.responseEnd]), logs: window.__logs||[],
    frames: window.__fm,
    lt: window.__lt, ev: window.__ev.slice(),
  }));
  fs.writeFileSync(`${OUTDIR}/${COND}${RUN}_raw.json`, JSON.stringify({ meta, ops, raw }));
  fs.writeFileSync(`${OUTDIR}/${COND}${RUN}_net.json`, JSON.stringify(NETLOG)); await b.close();
})().catch(e => { console.error(e); process.exit(1); });
