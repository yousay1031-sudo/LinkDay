// 先頭1文字欠落: Tab直後(wait=0)で多数試行し、欠落時のイベント列(keydown/beforeinput/input/focus)を保存
const L = require('./lib2'); const fs = require('fs');
const cred = JSON.parse(fs.readFileSync(require('os').homedir() + '/.linkday_verify/credentials.json', 'utf8'));
const N = +(process.env.N || 20), WAIT = +(process.env.WAIT || 0), SEM = process.env.SEM !== '0', MODE = process.env.MODE || 'fresh';
const OUT = '/home/user/flutter_app/docs/day15_input_investigation';
(async () => {
  const out = [];
  for (let t = 0; t < N; t++) {
    const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
    await page.goto(L.BASE, { waitUntil: 'load' }); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 90000 }); await L.sleep(1200);
    if (SEM) await L.enableSemantics(page);
    await page.evaluate(() => { window.__ev = []; const t0 = performance.now(); const d = e => (e.target && e.target.tagName ? e.target.tagName + '/' + (e.target.type || '') : '?');
      for (const t of ['keydown', 'beforeinput', 'input', 'focusin', 'focusout', 'compositionstart']) addEventListener(t, e => window.__ev.push(`${Math.round(performance.now() - t0)} ${t}${e.key ? ':' + e.key : ''}${e.data ? ':' + e.data : ''} @${d(e)}${e.target && 'value' in e.target ? ' v=' + e.target.value.length : ''}`), true); });
    await page.mouse.click(640, 402); await L.sleep(400);
    await page.keyboard.type(cred.email, { delay: 15 });
    await page.keyboard.press('Tab'); if (WAIT) await L.sleep(WAIT);
    await page.evaluate(() => window.__ev.push('--- pw typing starts ---'));
    await page.keyboard.type(cred.password, { delay: 15 }); await L.sleep(300);
    const pw = await page.evaluate(() => document.activeElement.value);
    const ok = pw === cred.password;
    let missing = null; if (!ok) { let i = 0; while (i < pw.length && pw[i] === cred.password[i]) i++; missing = i; }
    const ev = await page.evaluate(() => { const a = window.__ev; const i = a.findIndex(x => x.startsWith('---')); return a.slice(Math.max(0, i - 4), i + 14); });
    out.push({ t, ok, pwLen: pw.length, firstMismatchIndex: missing, evAroundPw: ok ? undefined : ev });
    console.log(JSON.stringify({ t, ok, pwLen: pw.length, firstMismatchIndex: missing }));
    await b.close();
  }
  const fails = out.filter(o => !o.ok).length; console.log(`SUMMARY wait=${WAIT} sem=${SEM} fails=${fails}/${N}`);
  fs.writeFileSync(`${OUT}/drop_wait${WAIT}_sem${SEM ? 1 : 0}.json`, JSON.stringify({ WAIT, SEM, N, fails, out }, null, 1));
})();
