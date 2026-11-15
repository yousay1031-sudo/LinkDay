const L = require('./lib2'); const fs = require('fs');
const RAW = '/home/user/day15_verify/v4/rm_raw'; fs.rmSync(RAW, { recursive: true, force: true }); fs.mkdirSync(RAW, { recursive: true });
const res = { env: {}, mq: {}, press: {}, entrance: {}, skeleton: {} };
const setMedia = (cdp, reduce) => cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: reduce ? 'reduce' : 'no-preference' }] });
const mq = page => page.evaluate(() => matchMedia('(prefers-reduced-motion: reduce)').matches);
async function pressTest(page, tag) {
  const n = (await L.nodes(page)).find(n => /^出席管理$/.test(n.label) && n.role === 'button');
  const cx = n.x + n.w / 2, cy = n.y + n.h / 2;
  const clip = { x: Math.max(0, n.x - 10), y: Math.max(0, n.y - 10), width: Math.min(390 - Math.max(0, n.x - 10), n.w + 20), height: n.h + 20 };
  await page.mouse.move(cx, cy); await L.sleep(300);
  const rect = async () => { await L.enableSemantics(page); const m = (await L.nodes(page)).find(m => /^出席管理$/.test(m.label) && m.role === 'button'); return m && { x: +m.x.toFixed(1), y: +m.y.toFixed(1), w: +m.w.toFixed(1), h: +m.h.toFixed(1) }; };
  const before = await rect(); await page.screenshot({ path: `${RAW}/press_${tag}_0before.png`, clip });
  await page.mouse.down(); await L.sleep(450);
  const during = await rect(); await page.screenshot({ path: `${RAW}/press_${tag}_1during.png`, clip });
  await page.mouse.move(cx, cy + 250, { steps: 6 }); await L.sleep(450); // 押下したまま外へ → 離してもタップにならない
  await page.mouse.up(); await L.sleep(500);
  const after = await rect();
  res.press[tag] = { before, during, after, widthShrinkPx: before && during ? +(before.w - during.w).toFixed(1) : null, heightShrinkPx: before && during ? +(before.h - during.h).toFixed(1) : null };
  console.log('press', tag, JSON.stringify(res.press[tag]));
}
async function entranceTest(page, tag) {
  const cdp = await page.createCDPSession(); const frames = []; let t0 = null;
  cdp.on('Page.screencastFrame', async f => { frames.push({ t: f.metadata.timestamp, d: f.data }); cdp.send('Page.screencastFrameAck', { sessionId: f.sessionId }).catch(() => {}); });
  await cdp.send('Page.startScreencast', { format: 'png', everyNthFrame: 1 });
  await L.sleep(200);
  const n = (await L.nodes(page)).find(n => /^出席管理$/.test(n.label) && n.role === 'button');
  await page.mouse.move(n.x + n.w / 2, n.y + n.h / 2); await L.sleep(150);
  const tClick = Date.now() / 1000;
  await page.mouse.down(); await L.sleep(60); await page.mouse.up();
  await L.sleep(2200);
  await cdp.send('Page.stopScreencast'); await cdp.detach();
  const dir = `${RAW}/ent_${tag}`; fs.mkdirSync(dir, { recursive: true });
  frames.forEach((f, i) => fs.writeFileSync(`${dir}/f${String(i).padStart(3, '0')}.png`, Buffer.from(f.d, 'base64')));
  fs.writeFileSync(`${dir}/ts.json`, JSON.stringify({ tClick, ts: frames.map(f => f.t) }));
  res.entrance[tag] = { frames: frames.length };
  await L.enableSemantics(page); await L.back(page, 1200);
  await L.enableSemantics(page);
}
async function skeletonTest(page, tag, count = 22) {
  const dir = `${RAW}/sk_${tag}`; fs.mkdirSync(dir, { recursive: true });
  const ts = [];
  for (let i = 0; i < count; i++) { await page.screenshot({ path: `${dir}/s${String(i).padStart(2, '0')}.png`, clip: { x: 0, y: 100, width: 390, height: 600 } }); ts.push(Date.now()); await L.sleep(60); }
  fs.writeFileSync(`${dir}/ts.json`, JSON.stringify(ts));
}
const setDelay = (page, v) => page.evaluate(v => { if (v) localStorage.setItem('flutter.verify_delay_ms', String(v)); else localStorage.removeItem('flutter.verify_delay_ms'); }, v);
(async () => {
  // ── 起動A: 通常起動 → 切替 (b)(c)
  let b = await L.launch(); let page = await b.newPage(); await page.setViewport({ width: 390, height: 844 });
  let cdp = await page.createCDPSession();
  await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
  res.mq.A_start = await mq(page); console.log('A start matchMedia', res.mq.A_start);
  await pressTest(page, 'A1_motion'); await entranceTest(page, 'A1_motion');
  await setMedia(cdp, true); await L.sleep(500); res.mq.A_reduce = await mq(page);
  await pressTest(page, 'A2_off_to_on'); await entranceTest(page, 'A2_off_to_on');
  await setMedia(cdp, false); await L.sleep(500); res.mq.A_back = await mq(page);
  await pressTest(page, 'A3_on_to_off'); await entranceTest(page, 'A3_on_to_off');
  // スケルトン (遅延注入は検証用機能。性能計測では使わない)
  await setDelay(page, 40000);
  const nb = (await L.nodes(page)).find(n => /^出席管理$/.test(n.label) && n.role === 'button');
  await page.mouse.move(nb.x + nb.w / 2, nb.y + nb.h / 2); await L.sleep(150); await page.mouse.down(); await L.sleep(60); await page.mouse.up(); await L.sleep(1500);
  await skeletonTest(page, 'A1_motion');
  await setMedia(cdp, true); await L.sleep(500); await skeletonTest(page, 'A2_off_to_on');
  await setMedia(cdp, false); await L.sleep(500); await skeletonTest(page, 'A3_on_to_off');
  await page.screenshot({ path: `${RAW}/sk_A3_full.png` });
  await setDelay(page, 0); await b.close();
  // ── 起動B: 起動時から有効 (--force-prefers-reduced-motion)
  b = await L.launch(['--force-prefers-reduced-motion']); page = await b.newPage(); await page.setViewport({ width: 390, height: 844 }); cdp = await page.createCDPSession();
  await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
  res.mq.B_start = await mq(page); console.log('B start matchMedia', res.mq.B_start);
  await pressTest(page, 'B1_initial_reduced'); await entranceTest(page, 'B1_initial_reduced');
  await setDelay(page, 40000);
  const nb2 = (await L.nodes(page)).find(n => /^出席管理$/.test(n.label) && n.role === 'button');
  await page.mouse.move(nb2.x + nb2.w / 2, nb2.y + nb2.h / 2); await L.sleep(150); await page.mouse.down(); await L.sleep(60); await page.mouse.up(); await L.sleep(1500);
  await skeletonTest(page, 'B1_initial_reduced');
  await setMedia(cdp, false); await L.sleep(500); res.mq.B_off = await mq(page); await skeletonTest(page, 'B2_reduced_to_motion');
  await setDelay(page, 0); await b.close();
  fs.writeFileSync('/home/user/day15_verify/v4/rm_result.json', JSON.stringify(res, null, 1));
})().catch(e => { console.error(e); process.exit(1); });
