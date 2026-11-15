const { launch, URL } = require('./lib');
(async () => {
  const browser = await launch(); const page = await browser.newPage();
  let navs = 0; page.on('framenavigated', f => { if (f === page.mainFrame()) navs++; });
  await page.goto(URL); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 60000 });
  console.log('first visit navigations', navs, 'sw flag', await page.evaluate(() => sessionStorage.getItem('ld_sw_reloading')));
  navs = 0; const ab = []; page.on('requestfailed', r => ab.push(r.url()));
  await page.reload(); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 60000 });
  console.log('2nd visit navigations', navs, 'aborted', ab.length);
  await browser.close();
})();
