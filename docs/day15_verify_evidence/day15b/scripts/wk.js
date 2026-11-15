const L = require('./lib2'); const fs = require('fs');
const W = +process.argv[2]; const TAG = process.argv[3];
const vp = W === 390 ? { width: 390, height: 844 } : { width: 1280, height: 800 };
const OUT = '/home/user/flutter_app/docs/day15_verify_evidence/day15b';
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport(vp); L.instrument(page, { console: [], failed: [] });
  await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
  await L.press(page, /^週間利用計画$/, { role: 'button', wait: 3500 });
  await page.screenshot({ path: `${OUT}/${TAG}_${W}_weekly.png` });
  await L.press(page, /^次の週$/, { role: 'button', wait: 3500 });
  await page.screenshot({ path: `${OUT}/${TAG}_${W}_weekly_next.png` });
  await b.close();
})();
