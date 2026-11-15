const { launch, URL } = require('./lib');
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  const browser = await launch(); const page = await browser.newPage(); await page.setViewport({ width: 1280, height: 800 });
  let step = 'boot';
  page.on('pageerror', e => console.log(`[pageerror @ ${step}]`, String(e.stack || e).slice(0, 600)));
  await page.goto(URL); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 60000 }); await sleep(1500);
  for (let i = 0; i < 6; i++) { step = 'tab' + (i + 1); await page.keyboard.press('Tab'); await sleep(400); }
  step = 'click-top'; await page.mouse.click(640, 0); await sleep(500);
  step = 'press-login'; await page.mouse.move(640, 571); await page.mouse.down(); await sleep(120); await page.mouse.up(); await sleep(800);
  step = 'click-email'; await page.mouse.click(640, 403); await sleep(400);
  step = 'type'; await page.keyboard.type('not-an-email'); await sleep(300);
  step = 'tab-pw'; await page.keyboard.press('Tab'); await sleep(300);
  step = 'type-pw'; await page.keyboard.type('abc'); await sleep(300);
  step = 'enter'; await page.keyboard.press('Enter'); await sleep(800);
  step = 'drag'; await page.mouse.move(640, 571); await page.mouse.down(); await page.mouse.move(640, 451, { steps: 8 }); await page.mouse.up(); await sleep(800);
  step = 'end'; await browser.close();
})();
