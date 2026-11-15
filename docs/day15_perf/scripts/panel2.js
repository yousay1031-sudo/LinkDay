const L = require('./lib2'); const fs = require('fs');
const OUT = '/home/user/flutter_app/docs/day15_perf/panel'; fs.mkdirSync(OUT, { recursive: true });
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 390, height: 844, hasTouch: true });
  await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
  await L.press(page, /^出席管理$/, { role: 'button', wait: 3000 });
  const stop = await L.recorder(page, '/home/user/day15_verify/v4/rec_panel2');
  const clip = { x: 0, y: 110, width: 390, height: 260 };
  const shot = n => page.screenshot({ path: `${OUT}/c_${n}.png`, clip });
  const rowFirst = async () => (await L.nodes(page)).filter(n => /^(募集中|確定|受付終了|再募集中)/.test(n.label) && n.h < 90)[0]?.y;
  const listCardY = async () => (await L.nodes(page)).filter(n => /^(入室|退室|欠席を取り消す)$/.test(n.label) && n.role==='button').map(n => Math.round(n.y))[0];
  const r = {};
  await shot('00'); r.panelY0 = await rowFirst(); r.listY0 = await listCardY();
  // 1) ホイール: パネル内 (段階ごとにクリップ画像)
  let k = 1;
  for (let i = 0; i < 6; i++) { await page.mouse.move(195, 250); await page.mouse.wheel({ deltaY: 50 }); await L.sleep(350); await shot(String(k++).padStart(2,'0')); }
  await L.enableSemantics(page); r.panelYAfterWheel = await rowFirst(); r.listYAfterPanelWheel = await listCardY();
  // 2) タッチドラッグ: パネル内で下向きに指を動かして上へ戻す
  const cdp = await page.createCDPSession();
  const swipe = async (x, y0, y1, ms = 300) => { await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y: y0 }] }); const steps = 15; for (let i = 1; i <= steps; i++) { await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x, y: y0 + (y1 - y0) * i / steps }] }); await L.sleep(ms / steps); } await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] }); await L.sleep(900); };
  await swipe(195, 200, 330); await L.enableSemantics(page); r.panelYAfterTouchDown = await rowFirst(); r.listYAfterPanelTouch = await listCardY(); await shot('touch_down');
  await swipe(195, 330, 200); await L.enableSemantics(page); r.panelYAfterTouchUp = await rowFirst(); await shot('touch_up');
  // 3) 下の出席一覧: 独立スクロール（パネルは動かない）
  const pBefore = await rowFirst(); const lBefore = await listCardY();
  for (let i = 0; i < 3; i++) { await page.mouse.move(195, 620); await page.mouse.wheel({ deltaY: 250 }); await L.sleep(300); }
  await L.sleep(500); await L.enableSemantics(page);
  r.listWheel = { panelBefore: pBefore, panelAfter: await rowFirst(), listBefore: lBefore, listAfter: await listCardY() };
  await swipe(195, 700, 450); await L.enableSemantics(page); r.listTouchListY = await listCardY(); r.listTouchPanelY = await rowFirst();
  // 4) 一覧の最下部まで → ボタン到達
  for (let i = 0; i < 25; i++) { await page.mouse.move(195, 620); await page.mouse.wheel({ deltaY: 600 }); await L.sleep(100); }
  await L.sleep(600); await L.enableSemantics(page); await page.screenshot({ path: `${OUT}/c_list_bottom.png` });
  const btns = (await L.nodes(page)).filter(n => n.role === 'button' && n.y > 0 && n.y < 844).map(n => `${n.label.replace(/\n/g,' ').slice(0,16)}@${Math.round(n.y)}+${Math.round(n.h)}`);
  r.bottomButtons = btns;
  // 最下部のボタンを実際に押せるか: 最後の「入室」「欠席」「退室」等のうち画面内の1つを押し反応を見る
  r.frames = await stop();
  fs.writeFileSync(`${OUT}/panel2_result.json`, JSON.stringify(r, null, 1)); console.log(JSON.stringify(r, null, 1));
  await b.close();
})();
