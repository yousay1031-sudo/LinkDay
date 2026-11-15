const { launch, OUT } = require('./lib');
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  const browser = await launch(); const page = await browser.newPage(); await page.setViewport({ width: 1280, height: 800 });
  await page.goto('http://localhost:5071/?step=preview'); await sleep(8000);
  await page.screenshot({ path: `${OUT}/7z_preview_1280_before_relayout.png`, clip: { x: 640, y: 455, width: 640, height: 60 } });
  await page.setViewport({ width: 1279, height: 800 }); await sleep(600); await page.setViewport({ width: 1280, height: 800 }); await sleep(1000);
  await page.screenshot({ path: `${OUT}/7z_preview_1280_after_relayout.png`, clip: { x: 640, y: 455, width: 640, height: 60 } });
  // 2回目訪問（フォントはHTTPキャッシュ済み）
  await page.reload(); await sleep(8000);
  await page.screenshot({ path: `${OUT}/7z_preview_1280_second_visit.png`, clip: { x: 640, y: 455, width: 640, height: 60 } });
  await page.setViewport({ width: 390, height: 844 }); await page.reload(); await sleep(8000);
  await page.screenshot({ path: `${OUT}/7z_preview_390_second_visit.png`, clip: { x: 0, y: 760, width: 390, height: 84 } });
  await page.setViewport({ width: 389, height: 844 }); await sleep(600); await page.setViewport({ width: 390, height: 844 }); await sleep(1000);
  await page.screenshot({ path: `${OUT}/7z_preview_390_after_relayout.png`, clip: { x: 0, y: 760, width: 390, height: 84 } });
  await browser.close();
})();
