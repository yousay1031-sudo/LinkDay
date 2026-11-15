const L = require('./lib2'); const fs = require('fs');
const OUT = '/home/user/flutter_app/docs/day15_perf/panel'; fs.mkdirSync(OUT, { recursive: true });
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 390, height: 844 });
  L.instrument(page, { console: [], failed: [] });
  await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
  await L.press(page, /^出席管理$/, { role: 'button', wait: 3000 }); await L.enableSemantics(page);
  const stop = await L.recorder(page, '/home/user/day15_verify/v4/rec_panel');
  const rows = async () => (await L.nodes(page)).filter(n => /募集中|確定|受付終了|再募集/.test(n.label) && n.h < 90);
  const seen = new Set(); const log = [];
  const snap = async (tag) => { const r = await rows(); r.forEach(n => seen.add(n.label.replace(/\n/g,' '))); log.push({ tag, n: r.length, firstY: r[0] && Math.round(r[0].y), lastY: r.length && Math.round(r[r.length-1].y), labels: r.map(n=>n.label.replace(/\n/g,' ').slice(0,30)) }); };
  await page.screenshot({ path: `${OUT}/p0_top.png` });
  await snap('initial');
  const all = await L.nodes(page);
  const panel = all.find(n => /LINE応募/.test(n.label));
  const first = (await rows())[0];
  console.log('panel', JSON.stringify(panel && {y:panel.y,h:panel.h,l:panel.label.slice(0,60)}), 'first', first && first.y);
  const px = 195, py = first ? first.y + first.h / 2 : 250;
  // ホイールでパネル内をスクロール
  for (let i = 0; i < 12; i++) { await page.mouse.move(px, py); await page.mouse.wheel({ deltaY: 60 }); await L.sleep(150); await L.enableSemantics(page); await snap('wheel' + i); }
  await page.screenshot({ path: `${OUT}/p1_wheel_bottom.png` });
  // ドラッグで上へ戻す
  await page.mouse.move(px, py); await page.mouse.down(); for (let i = 1; i <= 15; i++) { await page.mouse.move(px, py + i * 12); await L.sleep(16); } await page.mouse.up(); await L.sleep(600);
  await L.enableSemantics(page); await snap('after_drag_down'); await page.screenshot({ path: `${OUT}/p2_after_drag.png` });
  // 下の出席一覧のスクロール(パネルの下側でホイール)
  const before = await L.nodes(page); const cardsBefore = before.filter(n => n.role==='button' && n.y > 380 && n.h > 60).slice(0,3).map(n => Math.round(n.y));
  const panelSnapBefore = (await rows())[0]?.y;
  for (let i = 0; i < 6; i++) { await page.mouse.move(195, 650); await page.mouse.wheel({ deltaY: 300 }); await L.sleep(150); }
  await L.sleep(500); await L.enableSemantics(page);
  const after = await L.nodes(page); const cardsAfter = after.filter(n => n.role==='button' && n.y > 380 && n.h > 60).slice(0,3).map(n => Math.round(n.y));
  const panelSnapAfter = (await rows())[0]?.y;
  await page.screenshot({ path: `${OUT}/p3_list_scrolled.png` });
  // 重要ボタン到達: 画面内にあるボタン一覧
  const btns = (await L.nodes(page)).filter(n => n.role === 'button').map(n => `${n.label.replace(/\n/g,' ').slice(0,20)}@${Math.round(n.y)}+${Math.round(n.h)}`);
  const nrec = await stop();
  const res = { distinctRowsSeen: seen.size, seen: [...seen], cardsBefore, cardsAfter, panelFirstRowYBefore: panelSnapBefore, panelFirstRowYAfter: panelSnapAfter, buttonsAfterListScroll: btns, frames: nrec, log };
  fs.writeFileSync(`${OUT}/panel_result.json`, JSON.stringify(res, null, 1));
  console.log(JSON.stringify({ distinct: seen.size, cardsBefore, cardsAfter, panelSnapBefore, panelSnapAfter, btns, nrec }));
  console.log(log.map(l => `${l.tag}: n=${l.n} first=${l.firstY} last=${l.lastY}`).join('\n'));
  await b.close();
})();
