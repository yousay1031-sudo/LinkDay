const L = require('./lib2'); const fs = require('fs');
const W = +process.argv[2]; const TAG = process.argv[3] || 'x';
const vp = W === 390 ? { width: 390, height: 844 } : { width: 1280, height: 800 };
const OUT = '/home/user/flutter_app/docs/day15_verify_evidence/day15b'; fs.mkdirSync(OUT, { recursive: true });
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport(vp); L.instrument(page, { console: [], failed: [] });
  await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
  await L.press(page, /^出席管理$/, { role: 'button', wait: 2500 }); await L.enableSemantics(page);
  const shot = n => page.screenshot({ path: `${OUT}/${TAG}_${W}_${n}.png` });
  const info = async () => { const ns = await L.nodes(page); return ns.filter(n => /入室|欠席|退室|LINE応募|在室|応募|確定|予定/.test(n.label || '')).map(n => ({ r: n.role, l: (n.label||'').replace(/\n/g,' ').slice(0,40), y: Math.round(n.y), h: Math.round(n.h), b: Math.round(n.y+n.h) })); };
  await shot('a_top');
  const top = await info();
  // 最下部までスクロール
  const bx = vp.width / 2, by = vp.height * 0.6;
  for (let i = 0; i < 25; i++) { await page.mouse.move(bx, by); await page.mouse.wheel({ deltaY: 500 }); await L.sleep(120); }
  await L.sleep(700); await L.enableSemantics(page); await shot('b_bottom');
  const bot = await info();
  fs.writeFileSync(`${OUT}/${TAG}_${W}_att.json`, JSON.stringify({ vp, top, bot }, null, 1));
  console.log(JSON.stringify({ top: top.slice(0, 14), bot: bot.slice(-14) }, null, 0));
  await b.close();
})();
