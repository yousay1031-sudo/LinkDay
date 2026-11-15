const { launch, URL } = require('./lib');
(async () => {
  const browser = await launch(); const page = await browser.newPage();
  const ev = [];
  page.on('request', r => { if (/main.dart.js|canvaskit/.test(r.url())) ev.push(`REQ ${r.resourceType()} ${r.url().split('/').pop()} init=${r.initiator()?.type}`); });
  page.on('requestfinished', r => { if (/main.dart.js|canvaskit/.test(r.url())) ev.push(`OK  ${r.response()?.status()} ${r.resourceType()} ${r.url().split('/').pop()} fromCache=${r.response()?.fromCache()}`); });
  page.on('requestfailed', r => ev.push(`FAIL ${r.resourceType()} ${r.url().split('/').pop()} ${r.failure()?.errorText}`));
  await page.goto(URL); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 60000 });
  console.log(ev.join('\n'));
  console.log(await page.evaluate(() => [...document.querySelectorAll('link[rel=preload],link[rel=modulepreload]')].map(l => l.outerHTML)));
  await browser.close();
})();
