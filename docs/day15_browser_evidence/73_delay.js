const { launch, OUT } = require('./lib');
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  const browser = await launch(); const page = await browser.newPage();
  for (const [w, h, clip] of [[1280, 800, { x: 640, y: 455, width: 640, height: 60 }], [390, 844, { x: 0, y: 760, width: 390, height: 84 }]]) {
    await page.setViewport({ width: w, height: h });
    await page.goto('http://localhost:5073/?step=preview&delay=7000'); await sleep(10000);
    await page.screenshot({ path: `${OUT}/7z_preview_${w}_after_fonts.png`, clip });
  }
  await browser.close();
})();
