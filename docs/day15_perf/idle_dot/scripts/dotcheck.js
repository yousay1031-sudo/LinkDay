// 390px で静止ドットの見た目と 入室操作後の表示・集計更新を確認（検証用エミュレータのみ）
const L = require('./lib2'); const fs = require('fs');
const OUT = process.argv[2]; fs.mkdirSync(OUT, { recursive: true });
const cred = JSON.parse(fs.readFileSync(require('os').homedir() + '/.linkday_verify/credentials.json', 'utf8'));
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 390, height: 844 });
  await page.goto(L.BASE, { waitUntil: 'load' });
  await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 90000 }); await L.sleep(1500);
  await page.mouse.click(195, 424); await L.sleep(400); await page.keyboard.type(cred.email, { delay: 20 });
  await page.mouse.click(195, 520); await L.sleep(600); await page.keyboard.type(cred.password, { delay: 20 }); await page.keyboard.press('Enter');
  await L.sleep(5000);
  await page.mouse.move(195, 745); await L.sleep(120); await page.mouse.down(); await L.sleep(60); await page.mouse.up();
  await L.sleep(3500);
  await L.enableSemantics(page);
  const dump = async tag => { const n = await L.nodes(page); const l = n.filter(x => /予定|在室中|退室済|欠席|入室|退室/.test(x.label)).map(x => `${x.label.replace(/\s+/g,' ')}@${Math.round(x.x)},${Math.round(x.y)}`); console.log(tag, JSON.stringify(l.slice(0, 20))); return n; };
  await page.screenshot({ path: `${OUT}/dot_1_before_checkin.png` });
  const n1 = await dump('before');
  const btn = n1.find(x => /入室/.test(x.label) && x.role === 'button');
  if (!btn) { console.log('入室ボタン見つからず'); await b.close(); return; }
  console.log('tap 入室', btn.label.slice(0, 40));
  await page.mouse.move(btn.x + btn.w / 2, btn.y + btn.h / 2); await L.sleep(150); await page.mouse.down(); await L.sleep(60); await page.mouse.up();
  await L.sleep(3500);
  await page.screenshot({ path: `${OUT}/dot_2_after_checkin.png` });
  await dump('after');
  await b.close();
})().catch(e => { console.error(e); process.exit(1); });
