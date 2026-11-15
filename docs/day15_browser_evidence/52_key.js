const { launch, URL } = require('./lib');
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  const browser = await launch(); const page = await browser.newPage(); await page.setViewport({ width: 1280, height: 800 });
  let step = ''; page.on('pageerror', e => console.log(`ERR @ ${step}: ${String(e).slice(0, 80)}`));
  await page.goto(URL); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 60000 }); await sleep(1500);
  await page.evaluateOnNewDocument(() => {});
  await page.mouse.click(640, 403); await sleep(300);
  await page.evaluate(() => { window.__k = []; addEventListener('keydown', e => window.__k.push(`${e.key}|${e.code}|loc=${e.location}`), true); });
  for (const c of ['n', 'o', '-', 'a', '@', '.', '1']) { step = c; await page.keyboard.type(c); await sleep(300); }
  step = 'Minus-key'; await page.keyboard.press('Minus'); await sleep(300);
  step = 'NumpadSubtract'; await page.keyboard.press('NumpadSubtract'); await sleep(300);
  console.log(await page.evaluate(() => window.__k));
  await browser.close();
})();
