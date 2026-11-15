// 初回訪問(新規プロファイル)かどうかで例外・入力欠落が変わるかを比較。1試行=1ブラウザ。
const L = require('./lib2'); const fs = require('fs');
const cred = JSON.parse(fs.readFileSync(require('os').homedir() + '/.linkday_verify/credentials.json', 'utf8'));
const N = +(process.env.N || 6); const OUT = '/home/user/flutter_app/docs/day15_input_investigation';
(async () => {
  const out = [];
  for (const mode of ['fresh', 'second-visit']) for (let t = 0; t < N; t++) {
    const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
    let step = 'boot'; const ev = []; const t0 = Date.now();
    page.on('pageerror', e => ev.push({ ms: Date.now() - t0, step, kind: 'pageerror', msg: String(e.stack || e).slice(0, 900) }));
    page.on('console', m => { if (/InvalidState|Exception|TypeError/.test(m.text())) ev.push({ ms: Date.now() - t0, step, kind: 'console', msg: m.text().slice(0, 900) }); });
    page.on('framenavigated', f => { if (f === page.mainFrame()) ev.push({ ms: Date.now() - t0, step, kind: 'navigated', msg: f.url() }); });
    await page.goto(L.BASE, { waitUntil: 'load' });
    if (mode === 'second-visit') { await L.sleep(4000); await page.goto(L.BASE, { waitUntil: 'load' }); }
    await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 90000 }); await L.sleep(1200);
    await L.enableSemantics(page);
    const list = await L.nodes(page); const i = list.findIndex(n => /^メールアドレス$/.test(n.label) && n.h <= 24); const em = list.slice(i + 1).find(n => n.h >= 40 && n.w >= 300);
    step = 'click-email'; await page.mouse.click(em.x + em.w / 2, em.y + em.h / 2); await L.sleep(300);
    step = 'type-email'; await page.keyboard.type(cred.email, { delay: 15 }); const emailVal = await page.evaluate(() => document.activeElement.value);
    step = 'tab'; await page.keyboard.press('Tab'); await L.sleep(+(process.env.WAIT||0));
    step = 'type-pw'; await page.keyboard.type(cred.password, { delay: 15 }); await L.sleep(300);
    const pw = await page.evaluate(() => document.activeElement.value);
    step = 'enter'; await page.keyboard.press('Enter'); await L.sleep(4000);
    const r = { mode, t, emailOK: emailVal === cred.email, pwOK: pw === cred.password, pwLen: pw.length, events: ev.filter(e => e.kind !== 'navigated').map(e => `${e.ms}ms ${e.step} ${e.kind}: ${e.msg.slice(0, 90)}`), navs: ev.filter(e => e.kind === 'navigated').length };
    out.push({ ...r, full: ev }); console.log(JSON.stringify(r)); await b.close();
  }
  fs.writeFileSync(`${OUT}/fresh_vs_second_wait${process.env.WAIT||0}.json`, JSON.stringify(out, null, 1));
})().catch(e => { console.log('FATAL', e); process.exit(1); });
