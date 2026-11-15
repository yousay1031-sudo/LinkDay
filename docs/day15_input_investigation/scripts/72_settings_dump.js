const L = require('./lib2');
const ls = (page, k, v) => page.evaluate((k, v) => { if (v === null) localStorage.removeItem('flutter.' + k); else localStorage.setItem('flutter.' + k, v); }, k, v);
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
  await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
  await ls(page, 'verify_faults', '"settings"');
  await L.press(page, /^設定$/, { role: 'button', wait: 2500 });
  await page.mouse.move(640, 450); await page.mouse.wheel({ deltaY: 2100 }); await L.sleep(900); await L.enableSemantics(page);
  const html = await page.evaluate(() => [...document.querySelectorAll('flt-semantics')].map(e => { const r = e.getBoundingClientRect(); return { y: Math.round(r.y), h: Math.round(r.height), role: e.getAttribute('role'), aria: e.getAttribute('aria-label'), live: e.getAttribute('aria-live'), text: (e.childNodes.length && [...e.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join('|')) }; }).filter(x => x.y > 56 && x.y < 780));
  console.log(JSON.stringify(html, null, 0));
  await page.screenshot({ path: '/tmp/s_err.png' });
  await b.close();
})();
