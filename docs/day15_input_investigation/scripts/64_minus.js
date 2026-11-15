// 「−」: puppeteer が送るキーイベントの実体と、例外の有無を条件別に比較
const L = require('./lib2'); const fs = require('fs');
const OUT = '/home/user/flutter_app/docs/day15_input_investigation';
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
  let cur = ''; const errs = []; page.on('pageerror', e => errs.push({ cur, msg: String(e.stack || e).slice(0, 1200) }));
  page.on('console', m => { if (/TypeError|Exception/.test(m.text())) errs.push({ cur, msg: 'console: ' + m.text().slice(0, 1200) }); });
  const res = [];
  const cdp = await page.createCDPSession();
  const raw = (o) => cdp.send('Input.dispatchKeyEvent', o);
  const cases = {
    'puppeteer.type("-")': async () => page.keyboard.type('-'),
    'puppeteer.press("Minus")': async () => page.keyboard.press('Minus'),
    'puppeteer.press("NumpadSubtract")': async () => page.keyboard.press('NumpadSubtract'),
    'raw main-row minus (key=-, code=Minus, loc=0)': async () => { await raw({ type: 'keyDown', key: '-', code: 'Minus', text: '-', windowsVirtualKeyCode: 189, location: 0 }); await raw({ type: 'keyUp', key: '-', code: 'Minus', windowsVirtualKeyCode: 189, location: 0 }); },
    'raw numpad minus (key=-, code=NumpadSubtract, loc=3)': async () => { await raw({ type: 'keyDown', key: '-', code: 'NumpadSubtract', text: '-', windowsVirtualKeyCode: 109, location: 3 }); await raw({ type: 'keyUp', key: '-', code: 'NumpadSubtract', windowsVirtualKeyCode: 109, location: 3 }); },
    'raw key=-, code=NumpadSubtract, loc=0': async () => { await raw({ type: 'keyDown', key: '-', code: 'NumpadSubtract', text: '-', windowsVirtualKeyCode: 109, location: 0 }); await raw({ type: 'keyUp', key: '-', code: 'NumpadSubtract', windowsVirtualKeyCode: 109, location: 0 }); },
    'raw numpad plus (key=+, code=NumpadAdd, loc=3)': async () => { await raw({ type: 'keyDown', key: '+', code: 'NumpadAdd', text: '+', windowsVirtualKeyCode: 107, location: 3 }); await raw({ type: 'keyUp', key: '+', code: 'NumpadAdd', windowsVirtualKeyCode: 107, location: 3 }); },
    'raw numpad 5 (key=5, code=Numpad5, loc=3)': async () => { await raw({ type: 'keyDown', key: '5', code: 'Numpad5', text: '5', windowsVirtualKeyCode: 101, location: 3 }); await raw({ type: 'keyUp', key: '5', code: 'Numpad5', windowsVirtualKeyCode: 101, location: 3 }); },
  };
  for (const sem of [false, true]) for (const focus of ['email-field', 'none']) {
    await page.goto(L.BASE, { waitUntil: 'load' }); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 90000 }); await L.sleep(1200);
    if (sem) await L.enableSemantics(page);
    const em = { x: 430, y: 378.5, w: 420, h: 48 }; // 前回取得したログイン画面の入力欄座標(1280x800)
    if (focus === 'email-field') { await page.mouse.click(em.x + em.w / 2, em.y + em.h / 2); await L.sleep(500); }
    await page.evaluate(() => { window.__k = []; addEventListener('keydown', e => window.__k.push(`${e.key}|${e.code}|loc=${e.location}|kc=${e.keyCode}`), true); });
    for (const [name, fn] of Object.entries(cases)) {
      errs.length = 0; cur = name; await page.evaluate(() => { window.__k.length = 0; });
      await fn(); await L.sleep(400);
      const kd = await page.evaluate(() => window.__k.slice());
      const val = await page.evaluate(() => document.activeElement && 'value' in document.activeElement ? document.activeElement.value : null);
      const typeErr = errs.filter(e => /TypeError|toString/.test(e.msg));
      res.push({ sem, focus, case: name, keydown: kd, fieldValue: val, typeErrors: typeErr.length, firstStack: typeErr[0]?.msg });
      console.log(JSON.stringify({ sem, focus, case: name, kd: kd.join(','), val, typeErrors: typeErr.length }));
      if (focus === 'email-field') { await page.evaluate(() => { const a = document.activeElement; if (a && 'value' in a) a.value = ''; }); }
    }
  }
  fs.writeFileSync(`${OUT}/minus_matrix.json`, JSON.stringify(res, null, 1));
  await b.close();
})().catch(e => { console.log('FATAL', e); process.exit(1); });
