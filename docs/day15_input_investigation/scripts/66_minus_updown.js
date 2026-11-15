const L = require('./lib2'); const fs = require('fs');
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
  const out = []; let cur = ''; page.on('pageerror', e => out.push({ cur, err: String(e.message).slice(0, 80) }));
  await page.goto('http://127.0.0.1:8766/', { waitUntil: 'load' }); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 90000 }); await L.sleep(1500);
  await page.mouse.click(640, 402); await L.sleep(500);
  await page.evaluate(() => { window.__k = []; for (const t of ['keydown', 'keyup']) addEventListener(t, e => window.__k.push(`${t}:${e.key}|${e.code}|loc=${e.location}`), true); });
  const cdp = await page.createCDPSession(); const raw = o => cdp.send('Input.dispatchKeyEvent', o);
  const run = async (name, fn) => { cur = name; out.length = 0; await page.evaluate(() => { window.__k.length = 0; }); await fn(); await L.sleep(400); console.log(JSON.stringify({ name, events: await page.evaluate(() => window.__k.slice()), errors: out.length })); };
  await run('puppeteer down only NumpadSubtract', async () => { await page.keyboard.down('NumpadSubtract'); });
  await run('puppeteer up NumpadSubtract', async () => { await page.keyboard.up('NumpadSubtract'); });
  await run('raw down only loc=0 key=- code=NumpadSubtract', async () => { await raw({ type: 'keyDown', key: '-', code: 'NumpadSubtract', text: '-', windowsVirtualKeyCode: 109, location: 0 }); });
  await run('raw up loc=3(→1?) ', async () => { await raw({ type: 'keyUp', key: '-', code: 'NumpadSubtract', windowsVirtualKeyCode: 109, location: 3 }); });
  await run('raw down loc=3 only', async () => { await raw({ type: 'keyDown', key: '-', code: 'NumpadSubtract', text: '-', windowsVirtualKeyCode: 109, location: 3 }); });
  await run('raw up loc=0', async () => { await raw({ type: 'keyUp', key: '-', code: 'NumpadSubtract', windowsVirtualKeyCode: 109, location: 0 }); });
  await b.close();
})();
