const L = require('./lib2');
(async () => {
  for (const [w, h] of [[1280, 800], [390, 844]]) {
    const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: w, height: h, deviceScaleFactor: 1 });
    const log = { console: [], failed: [] }; L.instrument(page, log);
    await L.open(page);
    await page.screenshot({ path: `${L.OUT}/10_${w}_a_login.png` });
    await L.login(page); await L.sleep(3500);
    await page.screenshot({ path: `${L.OUT}/10_${w}_b_home.png` });
    console.log(w, 'LOG', JSON.stringify(log));
    await b.close();
  }
})();
