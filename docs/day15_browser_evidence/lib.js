const puppeteer = require('/home/user/perf_tools/node_modules/puppeteer-core');
const URL = process.env.URL || 'http://localhost:5060/';
const OUT = '/home/user/day15_verify/shots';
async function launch(extra = []) {
  return puppeteer.launch({
    executablePath: '/usr/bin/google-chrome', headless: 'new',
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--explicitly-allowed-ports=5060', ...extra],
  });
}
function instrument(page, log) {
  page.on('console', m => { if (['error', 'warning', 'warn'].includes(m.type())) log.console.push(`[${m.type()}] ${m.text().slice(0, 300)}`); });
  page.on('pageerror', e => log.console.push(`[pageerror] ${String(e).slice(0, 300)}`));
  page.on('requestfailed', r => log.failed.push(`${r.failure()?.errorText} ${r.url().slice(0, 160)}`));
  page.on('response', r => { if (r.status() >= 400) log.failed.push(`HTTP ${r.status()} ${r.url().slice(0, 160)}`); });
}
const bootState = page => page.evaluate(() => {
  const b = document.getElementById('ld-boot');
  return { exists: !!b, failed: b ? b.classList.contains('ld-failed') : false,
    failText: b ? document.getElementById('ld-fail-text').textContent : null,
    msg: b ? document.getElementById('ld-msg').textContent : null,
    flutter: !!document.querySelector('flutter-view, flt-glass-pane'), done: !!window.__ldBootDone };
});
module.exports = { launch, instrument, bootState, URL, OUT };
