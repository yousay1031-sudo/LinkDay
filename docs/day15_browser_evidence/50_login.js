const { launch, instrument, URL, OUT } = require('./lib');
const fs = require('fs');
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function recorder(page, dir) {
  fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(dir, { recursive: true });
  const cdp = await page.createCDPSession(); let n = 0; const times = [];
  cdp.on('Page.screencastFrame', async f => { const i = n++; times.push(f.metadata.timestamp); fs.writeFileSync(`${dir}/f${String(i).padStart(4, '0')}.jpg`, Buffer.from(f.data, 'base64')); cdp.send('Page.screencastFrameAck', { sessionId: f.sessionId }).catch(() => {}); });
  await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 70, everyNthFrame: 1 });
  return async () => { await cdp.send('Page.stopScreencast'); return { n, times }; };
}
(async () => {
  const [w, h] = process.argv[2].split('x').map(Number); const tag = `${w}`;
  const browser = await launch(); const page = await browser.newPage(); await page.setViewport({ width: w, height: h });
  const log = { console: [], failed: [] }; instrument(page, log);
  await page.goto(URL); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 60000 }); await sleep(1500);
  const S = async name => page.screenshot({ path: `${OUT}/5x_login_${tag}_${name}.png` });
  await S('a_initial');
  const stop = await recorder(page, `/home/user/day15_verify/frames/login_${tag}`);
  // キーボードフォーカス: Tab 順
  const focusInfo = [];
  for (let i = 0; i < 6; i++) { await page.keyboard.press('Tab'); await sleep(250);
    focusInfo.push(await page.evaluate(() => { const a = document.activeElement; return a ? `${a.tagName}${a.type ? '[' + a.type + ']' : ''}${a.getAttribute('aria-label') ? ' ' + a.getAttribute('aria-label') : ''}` : null; }));
    await S(`b_tab${i + 1}`); }
  console.log('TAB ORDER', JSON.stringify(focusInfo));
  // 空送信 → 検証エラー（ネットワーク送信なし）
  await page.mouse.click(w / 2, 0); await sleep(200);
  const btn = await page.evaluate(() => null);
  // ボタン位置は画面から推定: ログイン画面はスクロール中央。スクショ上の位置を使う
  const btnY = w >= 800 ? 571 : 593; const fieldY1 = w >= 800 ? 403 : 425; const fieldY2 = w >= 800 ? 499 : 521;
  // 押下保持（PressableScale）
  await page.mouse.move(w / 2, btnY); await page.mouse.down(); await sleep(120); await S('c_button_pressed'); await page.mouse.up(); await sleep(600);
  await S('d_validation_errors');
  // 不正メール
  await page.mouse.click(w / 2, fieldY1); await sleep(200); await page.keyboard.type('not-an-email'); await page.keyboard.press('Tab'); await page.keyboard.type('abc');
  await sleep(200); await page.keyboard.press('Enter'); await sleep(700); await S('e_invalid_input');
  // パスワード表示切替（キーボード）
  await sleep(300); await S('f_after_enter');
  // ドラッグ（スクロール）中に押下が誤発火しないか: ボタン上から開始して大きく動かす
  await page.mouse.move(w / 2, btnY); await page.mouse.down(); await page.mouse.move(w / 2, btnY - 120, { steps: 8 }); await sleep(100); await S('g_drag_from_button'); await page.mouse.up(); await sleep(600); await S('h_after_drag_release');
  // パスワードを忘れた方 → ダイアログ（送信しない）
  const linkY = w >= 800 ? 627 : 649;
  const [vh] = await page.evaluate(() => [innerHeight]);
  // ダイアログ表示前に検証メッセージで位置がずれるため、テキスト位置は再推定せずスクショで確認
  await stop();
  const frames = await stop.call ? null : null;
  console.log('log', JSON.stringify(log));
  await browser.close();
})();
