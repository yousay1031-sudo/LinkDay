const L = require('./lib2');
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
  const out = []; page.on('pageerror', e => out.push(String(e.message).slice(0, 80)));
  await page.goto('http://127.0.0.1:8766/', { waitUntil: 'load' }); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 90000 }); await L.sleep(1500);
  await page.mouse.click(640, 402); await L.sleep(500);
  await page.evaluate(() => { window.__k = []; for (const t of ['keydown', 'keyup']) addEventListener(t, e => window.__k.push(`${t}:${e.key}|${e.code}|loc=${e.location}`), true); });
  const cdp = await page.createCDPSession(); const raw = o => cdp.send('Input.dispatchKeyEvent', o);
  const run = async (name, fn) => { out.length = 0; await page.evaluate(() => { window.__k.length = 0; }); await fn(); await L.sleep(400);
    console.log(JSON.stringify({ name, events: await page.evaluate(() => window.__k.slice()), errors: out.length, value: await page.evaluate(() => document.activeElement.value) })); await page.evaluate(() => { document.activeElement.value = ''; }); };
  const base = { key: '-', code: 'NumpadSubtract', windowsVirtualKeyCode: 109 };
  await run('CDP isKeypad:true down+up (実テンキー相当)', async () => { await raw({ type: 'keyDown', ...base, text: '-', isKeypad: true }); await raw({ type: 'keyUp', ...base, isKeypad: true }); });
  await run('CDP isKeypad 無し down+up', async () => { await raw({ type: 'keyDown', ...base, text: '-' }); await raw({ type: 'keyUp', ...base }); });
  await run('CDP isKeypad:true を down のみ・up は無し', async () => { await raw({ type: 'keyDown', ...base, text: '-', isKeypad: true }); await raw({ type: 'keyUp', ...base }); });
  await run('通常の - (Minus) down+up', async () => { await raw({ type: 'keyDown', key: '-', code: 'Minus', text: '-', windowsVirtualKeyCode: 189 }); await raw({ type: 'keyUp', key: '-', code: 'Minus', windowsVirtualKeyCode: 189 }); });
  await run('puppeteer.keyboard.press(NumpadSubtract)', async () => { await page.keyboard.press('NumpadSubtract'); });
  await b.close();
})();
