// 例外の発生ステップ特定: 待機(メール入力後)・Enter 有無・セマンティクス有無
const L = require('./lib2'); const fs = require('fs');
const cred = JSON.parse(fs.readFileSync(require('os').homedir() + '/.linkday_verify/credentials.json', 'utf8'));
const N = +(process.env.N || 4); const OUT = '/home/user/flutter_app/docs/day15_input_investigation';
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
  let step = ''; const errs = []; page.on('pageerror', e => errs.push({ step, msg: String(e.stack || e).slice(0, 700) }));
  await L.open(page);
  const field = async lab => { const list = await L.nodes(page); const i = list.findIndex(n => lab.test(n.label) && n.h <= 24); return list.slice(i + 1).find(n => n.h >= 40 && n.w >= 300); };
  const em = await field(/^メールアドレス$/);
  const out = [];
  for (const sem of [false, true]) for (const afterEmail of [0, 200]) for (const enter of [false, true]) {
    for (let t = 0; t < N; t++) {
      errs.length = 0;
      await page.goto(L.BASE, { waitUntil: 'load' }); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 90000 }); await L.sleep(1200);
      if (sem) await L.enableSemantics(page);
      step = 'click-email'; await page.mouse.click(em.x + em.w / 2, em.y + em.h / 2); await L.sleep(300);
      step = 'type-email'; await page.keyboard.type(cred.email, { delay: 15 }); if (afterEmail) await L.sleep(afterEmail);
      step = 'tab'; await page.keyboard.press('Tab'); await L.sleep(500);
      step = 'type-pw'; await page.keyboard.type(cred.password, { delay: 15 }); await L.sleep(300);
      const pw = await page.evaluate(() => document.activeElement.value);
      if (enter) { step = 'enter'; await page.keyboard.press('Enter'); await L.sleep(2500); }
      const r = { sem, afterEmail, enter, t, pwOK: pw === cred.password, pwLen: pw.length, errSteps: errs.map(e => e.step + ':' + (/setSelectionRange/.test(e.msg) ? 'setSelectionRange' : e.msg.slice(0, 60))) };
      out.push({ ...r, stacks: errs.length ? errs.map(e => e.msg) : undefined }); console.log(JSON.stringify(r));
    }
  }
  fs.writeFileSync(`${OUT}/steps_result.json`, JSON.stringify(out, null, 1));
  await b.close();
})().catch(e => { console.log('FATAL', e); process.exit(1); });
