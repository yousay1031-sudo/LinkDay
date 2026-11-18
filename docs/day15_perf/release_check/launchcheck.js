// 通常 release ビルドの起動確認のみ（ログイン操作なし）
const L = require('./lib2'); const fs = require('fs');
const OUT = process.argv[2]; fs.mkdirSync(OUT, { recursive: true });
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 390, height: 844 });
  const cons = [], fails = [], reqs = new Set(), bad = [];
  page.on('console', m => { if (['error','warning','warn'].includes(m.type())) cons.push(`[${m.type()}] ${m.text().slice(0,300)}`); });
  page.on('pageerror', e => cons.push(`[pageerror] ${String(e).slice(0,300)}`));
  page.on('requestfailed', r => fails.push(`${r.failure()?.errorText} ${r.url().slice(0,160)}`));
  page.on('response', r => { if (r.status() >= 400) bad.push(`HTTP ${r.status()} ${r.url().slice(0,160)}`); });
  page.on('request', r => { try { reqs.add(new URL(r.url()).host); } catch (_) {} });
  const t0 = Date.now();
  await page.goto(L.BASE, { waitUntil: 'load' });
  const hadLoader = await page.evaluate(() => !!document.getElementById('ld-boot'));
  await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 90000 });
  const tLoader = Date.now() - t0; await L.sleep(3000);
  const info = await page.evaluate(() => ({ url: location.href, title: document.title, loader: !!document.getElementById('ld-boot'), glass: !!document.querySelector('flt-glass-pane'), sw: navigator.serviceWorker && navigator.serviceWorker.controller ? 'controlled' : 'none' }));
  await page.screenshot({ path: `${OUT}/release_launch_login.png` });
  console.log(JSON.stringify({ hadLoader, tLoader, info, hosts: [...reqs], cons, fails, bad }, null, 1));
  await b.close();
})().catch(e => { console.error(e); process.exit(1); });
