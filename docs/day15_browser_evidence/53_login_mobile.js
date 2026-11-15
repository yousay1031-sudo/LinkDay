const { launch, instrument, URL, OUT } = require('./lib');
const fs = require('fs');
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function recorder(page, dir) {
  fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(dir, { recursive: true });
  const cdp = await page.createCDPSession(); let n = 0;
  cdp.on('Page.screencastFrame', f => { fs.writeFileSync(`${dir}/f${String(n++).padStart(4, '0')}.jpg`, Buffer.from(f.data, 'base64')); cdp.send('Page.screencastFrameAck', { sessionId: f.sessionId }).catch(() => {}); });
  await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 70, maxWidth: 390, maxHeight: 844 });
  return async () => { await cdp.send('Page.stopScreencast'); return n; };
}
(async () => {
  const browser = await launch(); const page = await browser.newPage();
  await page.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 1 });
  const log = { console: [], failed: [] }; instrument(page, log);
  const stop = await recorder(page, '/home/user/day15_verify/frames/login_390');
  await page.goto(URL); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 60000 }); await sleep(1500);
  const S = n => page.screenshot({ path: `${OUT}/5x_login_390_${n}.png` });
  await S('a_initial');
  const ow = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth }));
  console.log('overflow check', ow);
  // タップでログイン（空）→ 検証表示
  await page.touchscreen.tap(195, 593); await sleep(800); await S('b_validation');
  // ボタン上から縦スワイプ（スクロール意図）→ 送信されないこと・押下表示が戻ること
  const cdp = await page.createCDPSession();
  const tp = (type, y) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x: 195, y }] });
  await tp('touchStart', 610); for (let y = 610; y >= 450; y -= 20) { await tp('touchMove', y); await sleep(16); } await S('c_swipe_mid'); await tp('touchEnd'); await sleep(700); await S('d_after_swipe');
  // パスワードを忘れた方 → ダイアログ（送信しない）
  await page.touchscreen.tap(195, 690); await sleep(900); await S('e_after_tap_forgot');
  const n = await stop();
  console.log('frames', n, 'log', JSON.stringify(log));
  await browser.close();
})();
