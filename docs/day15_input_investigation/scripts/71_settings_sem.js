const L = require('./lib2');
const ls = (page, k, v) => page.evaluate((k, v) => { if (v === null) localStorage.removeItem('flutter.' + k); else localStorage.setItem('flutter.' + k, v); }, k, v);
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
  await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
  await ls(page, 'verify_faults', '"settings"');
  await L.press(page, /^設定$/, { role: 'button', wait: 2500 });
  for (let i = 0; i < 9; i++) {
    const ns = (await L.nodes(page)).filter(n => n.y > 56 && n.y < 780);
    const hit = ns.filter(n => /APIキー|再試行|読み込/.test(n.label));
    console.log(`scroll ${i * 350}: nodes=${ns.length}`, JSON.stringify(hit.map(n => [n.role, n.label.slice(0, 30), Math.round(n.y)])));
    await page.mouse.move(640, 450); await page.mouse.wheel({ deltaY: 350 }); await L.sleep(500); await L.enableSemantics(page);
  }
  await b.close();
})();
