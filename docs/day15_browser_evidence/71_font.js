const { launch, OUT } = require('./lib');
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  const browser = await launch(); const page = await browser.newPage(); await page.setViewport({ width: 390, height: 844 });
  const fonts = []; page.on('requestfinished', r => { if (/fonts\.gstatic|\.woff|\.ttf|\.otf/.test(r.url())) fonts.push(`${Date.now() % 100000} ${r.response()?.status()} ${r.url().slice(0, 110)}`); });
  page.on('requestfailed', r => { if (/font/.test(r.url())) fonts.push('FAIL ' + r.url()); });
  const t0 = Date.now(); await page.goto('http://localhost:5072/?step=resolve');
  for (const t of [2, 5, 9]) { await sleep(t * 1000 - (Date.now() - t0)); await page.screenshot({ path: `${OUT}/7y_resolve_390_t${t}s.png` }); }
  console.log(fonts.join('\n')); await browser.close();
})();
