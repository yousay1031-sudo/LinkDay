const L = require('./lib2'); const fs = require('fs');
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
  let stack = null; page.on('pageerror', e => { if (!stack) stack = String(e.stack || e); });
  await page.goto('http://127.0.0.1:8766/', { waitUntil: 'load' }); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 90000 }); await L.sleep(1500);
  await page.mouse.click(640, 402); await L.sleep(500);
  await page.keyboard.press('NumpadSubtract'); await L.sleep(500);
  fs.writeFileSync('/tmp/dbg_stack.txt', stack || 'NO ERROR'); console.log(stack);
  await b.close();
})();
