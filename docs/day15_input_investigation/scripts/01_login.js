const L = require('./lib2');
(async () => {
  const [w, h] = (process.argv[2] || '1280x800').split('x').map(Number);
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: w, height: h });
  const log = { console: [], failed: [] }; L.instrument(page, log);
  await L.open(page);
  await page.screenshot({ path: `${L.OUT}/01_login_${w}_a_initial.png` });
  console.log('LABELS', JSON.stringify((await L.nodes(page)).map(n => n.label)));
  await L.login(page);
  await L.sleep(4000);
  await page.screenshot({ path: `${L.OUT}/01_login_${w}_b_after.png` });
  console.log('AFTER', JSON.stringify((await L.nodes(page)).map(n => n.label).slice(0, 30)));
  console.log('LOG', JSON.stringify(log, null, 1));
  await b.close();
})();
