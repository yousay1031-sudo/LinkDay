const L = require('./lib2'); const fs = require('fs');
const OUT = '/home/user/flutter_app/docs/day15_perf/panel';
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 390, height: 844 });
  await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
  await L.press(page, /^出席管理$/, { role: 'button', wait: 3000 });
  const r = {};
  // パネルを最下部までスクロールした状態で、画面内の「入室」を押す
  for (let i = 0; i < 8; i++) { await page.mouse.move(195, 250); await page.mouse.wheel({ deltaY: 80 }); await L.sleep(120); }
  await L.sleep(500); await L.enableSemantics(page);
  const sum = async () => (await L.nodes(page)).filter(n => /^(予定|在室中|退室済|欠席)/.test(n.label) && n.y < 110 && n.y > 60).map(n => n.label.replace(/\n/g, ' '));
  r.before = await sum();
  const nyu = (await L.nodes(page)).filter(n => n.role === 'button' && /^入室$/.test(n.label) && n.y > 300 && n.y < 790)[0];
  r.nyuPos = nyu && [Math.round(nyu.x), Math.round(nyu.y)];
  await page.mouse.move(nyu.x + nyu.w / 2, nyu.y + nyu.h / 2); await L.sleep(150); await page.mouse.down(); await L.sleep(70); await page.mouse.up(); await L.sleep(1500);
  await L.enableSemantics(page); r.afterEnter = await sum(); await page.screenshot({ path: `${OUT}/btn_after_enter.png` });
  // 一覧を最下部まで → 一番下のボタン(欠席を取り消す)を押す
  for (let i = 0; i < 25; i++) { await page.mouse.move(195, 620); await page.mouse.wheel({ deltaY: 600 }); await L.sleep(80); }
  await L.sleep(600); await L.enableSemantics(page);
  const last = (await L.nodes(page)).filter(n => n.role === 'button' && /取り消す/.test(n.label)).pop();
  r.lastBtn = last && { y: Math.round(last.y), h: Math.round(last.h) };
  await page.mouse.move(last.x + last.w / 2, last.y + 8); await L.sleep(150); await page.mouse.down(); await L.sleep(70); await page.mouse.up(); await L.sleep(1500);
  await L.enableSemantics(page); r.afterCancelAbsent = await sum(); await page.screenshot({ path: `${OUT}/btn_after_cancelabsent.png` });
  fs.writeFileSync(`${OUT}/panel3_result.json`, JSON.stringify(r, null, 1)); console.log(JSON.stringify(r));
  await b.close();
})();
