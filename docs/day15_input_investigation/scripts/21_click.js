const L = require('./lib2');
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
  page.on('console', m => console.log('c:', m.text().slice(0, 160)));
  await L.open(page); await L.login(page); await L.sleep(3500);
  await L.enableSemantics(page);
  const n = (await L.nodes(page)).filter(n => n.role === 'button' && /出席管理/.test(n.label))[0];
  console.log('target', JSON.stringify(n));
  await page.mouse.move(n.x + n.w / 2, n.y + n.h / 2); await L.sleep(200);
  await page.mouse.down(); await L.sleep(80); await page.mouse.up(); await L.sleep(2500);
  await page.screenshot({ path: `${L.OUT}/21_after_click.png` });
  console.log((await L.nodes(page)).map(n => n.label.slice(0, 20)).filter(x => x).slice(0, 14).join(' | '));
  await b.close();
})();
