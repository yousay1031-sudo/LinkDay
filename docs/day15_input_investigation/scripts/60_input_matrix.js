// 入力不具合の切り分け: セマンティクス有無 × 入力速度 × Tab後待機 を総当たりで比較
const L = require('./lib2'); const fs = require('fs');
const cred = JSON.parse(fs.readFileSync(require('os').homedir() + '/.linkday_verify/credentials.json', 'utf8'));
const N = +(process.env.N || 6);
const OUT = '/home/user/flutter_app/docs/day15_input_investigation';
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
  const errs = []; page.on('pageerror', e => errs.push(String(e).slice(0, 160)));
  // 1) セマンティクス有効で入力欄の座標を取得
  await L.open(page);
  const em = await (async () => { const list = await L.nodes(page); const i = list.findIndex(n => /^メールアドレス$/.test(n.label) && n.h <= 24); return list.slice(i + 1).find(n => n.h >= 40 && n.w >= 300); })();
  const pw0 = await (async () => { const list = await L.nodes(page); const i = list.findIndex(n => /^パスワード$/.test(n.label) && n.h <= 24); return list.slice(i + 1).find(n => n.h >= 40 && n.w >= 300); })();
  console.log('field rects', JSON.stringify({ em, pw0 }));
  const results = [];
  const conds = [];
  for (const sem of [false, true]) for (const delay of [0, 15, 60]) for (const wait of [0, 100, 500]) conds.push({ sem, delay, wait });
  for (const c of conds) {
    let r = { ...c, trials: [] };
    for (let t = 0; t < N; t++) {
      errs.length = 0;
      await page.goto(L.BASE, { waitUntil: 'load' });
      await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 90000 }); await L.sleep(1200);
      if (c.sem) await L.enableSemantics(page);
      await page.evaluate(() => { window.__ev = []; for (const t of ['keydown', 'beforeinput', 'input']) addEventListener(t, e => window.__ev.push(t === 'keydown' ? `kd:${e.key}` : `${t}:${e.data ?? ''}|v=${e.target.value ?? ''}`), true); });
      await page.mouse.click(em.x + em.w / 2, em.y + em.h / 2); await L.sleep(500);
      const f1 = await page.evaluate(() => { const a = document.activeElement; return `${a.tagName}|${a.type}`; });
      await page.keyboard.type(cred.email, { delay: c.delay }); await L.sleep(200);
      const emailVal = await page.evaluate(() => document.activeElement.value);
      await page.keyboard.press('Tab'); await L.sleep(c.wait);
      const f2 = await page.evaluate(() => { const a = document.activeElement; return `${a.tagName}|${a.type}`; });
      await page.keyboard.type(cred.password, { delay: c.delay }); await L.sleep(300);
      const pwVal = await page.evaluate(() => document.activeElement.value);
      const ev = await page.evaluate(() => window.__ev.slice(-60));
      r.trials.push({ focus1: f1, focus2: f2, emailOK: emailVal === cred.email, pwOK: pwVal === cred.password, pwLen: pwVal.length, pwFirst: pwVal === cred.password ? '' : (pwVal[0] === cred.password[0] ? 'first-ok' : 'FIRST-DROPPED?'), errs: [...errs], evTail: (emailVal !== cred.email || pwVal !== cred.password) ? ev : undefined });
    }
    const s = { ...c, n: N, emailFail: r.trials.filter(x => !x.emailOK).length, pwFail: r.trials.filter(x => !x.pwOK).length, selErr: r.trials.filter(x => x.errs.some(e => /setSelectionRange/.test(e))).length, otherErr: r.trials.filter(x => x.errs.some(e => !/setSelectionRange/.test(e))).length, focus2: [...new Set(r.trials.map(x => x.focus2))] };
    console.log(JSON.stringify(s)); results.push({ summary: s, trials: r.trials });
    fs.writeFileSync(`${OUT}/matrix_result.json`, JSON.stringify(results, null, 1));
  }
  await b.close();
})().catch(e => { console.log('FATAL', e); process.exit(1); });
