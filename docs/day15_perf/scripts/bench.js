// 使い方: node bench.js <motion|reduce> <run> <trace:1|0> <outdir>
const L = require('./lib2'); const fs = require('fs'); const zlib = require('zlib');
const [COND, RUN, TRACE, OUTDIR] = [process.argv[2], process.argv[3], process.argv[4] === '1', process.argv[5]];
fs.mkdirSync(OUTDIR + '/traces', { recursive: true });
const sleep = L.sleep; const REC = process.env.REC === '1'; const RECDIR = OUTDIR + '/rec_' + COND + RUN;
const cred = JSON.parse(fs.readFileSync(require('os').homedir() + '/.linkday_verify/credentials.json', 'utf8'));
const CATS = ['devtools.timeline', 'disabled-by-default-devtools.timeline', 'disabled-by-default-devtools.timeline.frame', 'blink.user_timing', 'toplevel', 'gpu'];
const P = { card: { att: [195, 745], cust: [195, 205] }, back: [28, 28], dateBtn: [287, 28], day: d => [[28 + 47.7 * ((d - 1) % 7) + 24, 358 + 48 * Math.floor((d - 1) / 7) + 24]][0], ok: [338, 680] };
const dayPos = d => { // 11月: 1日=日曜。ダンプ値 (x:28+47.67*col, y:358+48*row) の中心
  const i = d - 1, col = i % 7, row = Math.floor(i / 7); return [28 + 47.67 * col + 24, 358 + 48 * row + 24]; };
async function tap(page, [x, y]) { await page.mouse.move(x, y); await sleep(120); await page.mouse.down(); await sleep(60); await page.mouse.up(); }
async function pageTitle(page) { return page.screenshot({ encoding: 'base64' }).then(s => s.length); }
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 390, height: 844 });
  const cdp = await page.createCDPSession();
  await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: COND === 'reduce' ? 'reduce' : 'no-preference' }] });
  await page.evaluateOnNewDocument(() => {
    window.__lt = []; window.__ev = []; window.__fm = [];
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
    const tStart = Date.now() / 1000;
    await fn();
    if (REC) { await rcdp.send('Page.stopScreencast'); const dd = `${RECDIR}/${name}`; fs.mkdirSync(dd, { recursive: true }); fs.writeFileSync(`${dd}/ts.json`, JSON.stringify({ tStart, ts: rframes.map(f => f[0]) })); rframes.forEach((f, i) => fs.writeFileSync(`${dd}/f${String(i).padStart(4, '0')}.jpg`, Buffer.from(f[1], 'base64'))); await rcdp.detach(); }
    ops.push({ name, ev: await page.evaluate(() => window.__ev.slice()) });
    if (TRACE) await page.tracing.stop();
  }
  const shotBefore = async n => page.screenshot({ path: `${OUTDIR}/${COND}${RUN}_${n}.png` });
  // A: ホーム → 出席画面
  await traced('A', async () => { await tap(page, P.card.att); await sleep(3000); });
  await shotBefore('A_after');
  // C: 日付 15 → 14（ピッカー表示までは計測外。「決定」押下をもって開始）
  await sleep(1500);
  await tap(page, P.dateBtn); await sleep(1500); await tap(page, dayPos(14)); await sleep(600);
  await traced('C', async () => { await tap(page, P.ok); await sleep(3000); });
  await shotBefore('C_after');
  await tap(page, P.back); await sleep(2500);
  // B: 顧客一覧（60名）のスクロール。30回 × deltaY150(=4500px) / 66ms 間隔 ≒ 2s
  await tap(page, P.card.cust); await sleep(3000);
  await shotBefore('B_before');
  await traced('B', async () => { await scrollRun(30, 150, 66); await sleep(1000); });
  await shotBefore('B_after');
  // 収集
  const raw = await page.evaluate(() => ({
    frames: window.__fm,
    lt: window.__lt, ev: window.__ev.slice(),
  }));
  fs.writeFileSync(`${OUTDIR}/${COND}${RUN}_raw.json`, JSON.stringify({ meta, ops, raw }));
  await b.close();
})().catch(e => { console.error(e); process.exit(1); });
