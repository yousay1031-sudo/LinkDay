const { launch, instrument, bootState, URL, OUT } = require('./lib');
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function fresh(vp = { width: 390, height: 844 }) {
  const browser = await launch(); const page = await browser.newPage(); await page.setViewport(vp);
  const log = { console: [], failed: [] }; instrument(page, log);
  const cdp = await page.createCDPSession(); await cdp.send('Network.enable');
  return { browser, page, log, cdp };
}
const res = {};
(async () => {
  const which = process.argv[2];
  // ── 2a: キャッシュ無効 + 中速 (4Mbps, 150ms) ──
  if (which === 'slow') {
    const { browser, page, log, cdp } = await fresh();
    await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });
    await cdp.send('Network.setBypassServiceWorker', { bypass: true });
    await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 150, downloadThroughput: 4e6 / 8, uploadThroughput: 1e6 / 8 });
    const t0 = Date.now(); page.goto(URL).catch(() => {});
    const snaps = [];
    for (let i = 0; i < 60; i++) { await sleep(1000); const s = await bootState(page).catch(() => null); snaps.push(`${i + 1}s ${JSON.stringify(s)}`);
      if (i % 4 === 0) await page.screenshot({ path: `${OUT}/20_slow_${String(i + 1).padStart(2, '0')}s.png` }).catch(() => {});
      if (s && !s.exists) break; }
    await sleep(1500); await page.screenshot({ path: `${OUT}/20_slow_final.png` });
    console.log(snaps.join('\n')); console.log('elapsed', Date.now() - t0, JSON.stringify(log));
    await browser.close();
  }
  // ── 2b+5: キャッシュ無効 + 低速 (1.2Mbps) → 20s タイムアウト案内 → その後起動完了 ──
  if (which === 'veryslow') {
    const { browser, page, log, cdp } = await fresh();
    await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });
    await cdp.send('Network.setBypassServiceWorker', { bypass: true });
    await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 300, downloadThroughput: 1.2e6 / 8, uploadThroughput: 5e5 / 8 });
    const t0 = Date.now(); page.goto(URL, { timeout: 0 }).catch(() => {});
    let sawFail = false, shotFail = false;
    for (let i = 0; i < 150; i++) { await sleep(1000); const s = await bootState(page).catch(() => null);
      if (s && s.failed && !shotFail) { shotFail = true; sawFail = true; console.log(`timeout UI at ${i + 1}s`, JSON.stringify(s)); await page.screenshot({ path: `${OUT}/21_veryslow_timeout_ui.png` }); }
      if (i % 10 === 0) console.log(`${i + 1}s`, JSON.stringify(s));
      if (s && !s.exists) { console.log(`boot removed at ${i + 1}s`, JSON.stringify(s)); break; } }
    await sleep(2000);
    const after = await bootState(page);
    console.log('after', JSON.stringify(after), 'sawFail', sawFail);
    await page.screenshot({ path: `${OUT}/21_veryslow_after_boot.png` });
    console.log('elapsed', Date.now() - t0, JSON.stringify(log));
    await browser.close();
  }
  // ── 3+4: main.dart.js 遮断 → 失敗UI → 遮断解除して再読み込み ──
  if (which === 'block') {
    for (const target of ['main.dart.js', 'flutter_bootstrap.js']) {
      const { browser, page, log, cdp } = await fresh();
      await cdp.send('Network.setBypassServiceWorker', { bypass: true });
      let blocking = true;
      await page.setRequestInterception(true);
      page.on('request', r => { if (blocking && r.url().split('?')[0].endsWith('/' + target)) r.abort('failed'); else r.continue(); });
      await page.goto(URL); await sleep(5000);
      const s = await bootState(page);
      const focus = await page.evaluate(() => document.activeElement && document.activeElement.id);
      const btn = await page.evaluate(() => { const b = document.getElementById('ld-reload'); const r = b.getBoundingClientRect(); return { visible: r.height > 0, h: r.height, w: r.width, text: b.textContent }; });
      console.log(target, 'BLOCKED', JSON.stringify(s), 'focus=', focus, JSON.stringify(btn));
      const tag = target.replace(/\W/g, '_');
      await page.screenshot({ path: `${OUT}/30_block_${tag}_failui.png` });
      // キーボードで再読み込み（フォーカス済みボタンに Enter）
      blocking = false;
      await page.keyboard.press('Enter');
      await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 60000 }).then(() => console.log('recovered after reload')).catch(e => console.log('NOT recovered', e.message));
      await sleep(2000);
      console.log('after reload', JSON.stringify(await bootState(page)));
      await page.screenshot({ path: `${OUT}/31_block_${tag}_recovered.png` });
      console.log('log', JSON.stringify(log));
      await browser.close();
    }
  }
  // ── 6: prefers-reduced-motion ──
  if (which === 'reduce') {
    for (const mode of ['no-preference', 'reduce']) {
      const { browser, page, cdp } = await fresh();
      await page.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: mode }]);
      await cdp.send('Network.setBypassServiceWorker', { bypass: true });
      await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });
      await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 200, downloadThroughput: 2e6 / 8, uploadThroughput: 1e6 / 8 });
      page.goto(URL, { timeout: 0 }).catch(() => {}); await sleep(1500);
      const st = await page.evaluate(() => { const sp = document.querySelector('#ld-boot .ld-spinner'); const b = document.getElementById('ld-boot'); const cs = getComputedStyle(sp);
        return { animationName: cs.animationName, opacity: cs.opacity, transform: cs.transform, bootTransition: getComputedStyle(b).transitionDuration, mm: matchMedia('(prefers-reduced-motion: reduce)').matches }; });
      const t1 = await page.evaluate(() => getComputedStyle(document.querySelector('#ld-boot .ld-spinner')).transform);
      await sleep(230);
      const t2 = await page.evaluate(() => getComputedStyle(document.querySelector('#ld-boot .ld-spinner')).transform);
      console.log(mode, JSON.stringify(st), 'transform changes:', t1 !== t2, t1, t2);
      await page.screenshot({ path: `${OUT}/40_reduce_${mode}.png` });
      await browser.close();
    }
  }
})();
