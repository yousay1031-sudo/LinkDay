const { launch, instrument, OUT } = require('./lib');
const fs = require('fs');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const cases = [
  ['import_pick', 'http://localhost:5071/?step=pick'],
  ['import_preview', 'http://localhost:5071/?step=preview'],
  ['import_result', 'http://localhost:5071/?step=result'],
  ['resolve', 'http://localhost:5072/?step=resolve'],
  ['edit', 'http://localhost:5072/?step=edit'],
];
(async () => {
  const only = process.argv[2];
  for (const [w, h] of [[1280, 800], [390, 844]]) for (const [name, url] of cases) {
    if (only && !name.startsWith(only)) continue;
    const browser = await launch(); const page = await browser.newPage(); await page.setViewport({ width: w, height: h });
    const log = { console: [], failed: [] }; instrument(page, log);
    const dir = `/home/user/day15_verify/frames/h_${name}_${w}`; fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(dir, { recursive: true });
    const cdp = await page.createCDPSession(); let n = 0;
    cdp.on('Page.screencastFrame', f => { fs.writeFileSync(`${dir}/f${String(n++).padStart(4, '0')}.jpg`, Buffer.from(f.data, 'base64')); cdp.send('Page.screencastFrameAck', { sessionId: f.sessionId }).catch(() => {}); });
    await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 60, maxWidth: w, maxHeight: h });
    await page.goto(url, { waitUntil: 'networkidle0', timeout: 60000 }).catch(e => console.log('goto', e.message));
    await page.waitForFunction(() => document.fonts && document.fonts.status === 'loaded'); await sleep(6000);
    await page.screenshot({ path: `${OUT}/7x_${name}_${w}_a.png` });
    // スクロール（ホイール）
    await page.mouse.move(w / 2, h / 2); await page.mouse.wheel({ deltaY: 600 }); await sleep(700);
    await page.screenshot({ path: `${OUT}/7x_${name}_${w}_b_scrolled.png` });
    await cdp.send('Page.stopScreencast');
    const ow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    console.log(name, w, 'frames', n, 'hOverflowPx', ow, 'console', JSON.stringify(log.console.slice(0, 5)), 'failed', log.failed.filter(x => !/ERR_ABORTED/.test(x)).length);
    await browser.close();
  }
})();
