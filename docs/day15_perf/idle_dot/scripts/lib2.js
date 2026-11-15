const puppeteer = require('/home/user/perf_tools/node_modules/puppeteer-core');
const fs = require('fs');
const BASE = process.env.BASE || 'http://127.0.0.1:8765/';
const OUT = process.env.OUT || '/home/user/day15_verify/v2/shots';
fs.mkdirSync(OUT, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const cred = JSON.parse(fs.readFileSync(require('os').homedir() + '/.linkday_verify/credentials.json', 'utf8'));

// --explicitly-allowed-ports は使わない（標準設定の Chrome で開ける 8765 を使う）
async function launch(extra = []) {
  return puppeteer.launch({
    executablePath: '/usr/bin/google-chrome', headless: 'new',
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', ...extra],
  });
}
function instrument(page, log) {
  page.on('console', m => { if (['error', 'warning', 'warn'].includes(m.type())) log.console.push(`[${m.type()}] ${m.text().slice(0, 400)}`); });
  page.on('pageerror', e => log.console.push(`[pageerror] ${String(e).slice(0, 400)}`));
  page.on('requestfailed', r => log.failed.push(`${r.failure()?.errorText} ${r.url().slice(0, 140)}`));
  page.on('response', r => { if (r.status() >= 400) log.failed.push(`HTTP ${r.status()} ${r.url().slice(0, 140)}`); });
}
async function open(page, query = '') {
  await page.goto(BASE + query, { waitUntil: 'load' });
  await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 90000 });
  await sleep(1200);
  await enableSemantics(page);
}
// Flutter Web のアクセシビリティツリーを有効化（位置取得用。操作自体は実マウス/実キーボード）
async function enableSemantics(page) {
  await page.evaluate(() => { const p = document.querySelector('flt-semantics-placeholder'); if (p) p.click(); });
  await sleep(600);
}
// セマンティクスノード一覧（ラベル・位置）
const nodes = page => page.evaluate(() => [...document.querySelectorAll('flt-semantics')].map(e => {
  const r = e.getBoundingClientRect();
  return { label: (e.getAttribute('aria-label') || e.textContent || '').trim().slice(0, 80), role: e.getAttribute('role') || '', x: r.x, y: r.y, w: r.width, h: r.height };
}).filter(n => n.w > 0 && n.h > 0));
async function find(page, re, { role } = {}) {
  const list = await nodes(page);
  return list.find(n => re.test(n.label) && (!role || n.role === role));
}
async function clickLabel(page, re, opts = {}) {
  let n;
  for (let i = 0; i < 20 && !n; i++) { n = await find(page, re, opts); if (!n) await sleep(300); }
  if (!n) throw new Error('not found: ' + re);
  await page.mouse.click(n.x + n.w / 2, n.y + n.h / 2);
  return n;
}
// 入力欄: ラベルノードの直下にある同幅のノードをクリック（実マウス）
async function clickField(page, labelRe) {
  const list = await nodes(page);
  const i = list.findIndex(n => labelRe.test(n.label) && n.h <= 24);
  const f = list.slice(i + 1).find(n => n.h >= 40 && n.w >= 300);
  if (i < 0 || !f) throw new Error('field not found ' + labelRe);
  await page.mouse.click(f.x + f.w / 2, f.y + f.h / 2);
  return f;
}
async function login(page) {
  await clickField(page, /^メールアドレス$/);
  await sleep(300);
  await page.keyboard.type(cred.email, { delay: 15 });
  await page.keyboard.press('Tab');
  await sleep(500); // フォーカス移動直後の先頭文字の取りこぼし対策（2回に1回、先頭1文字が欠けた）
  await page.keyboard.type(cred.password, { delay: 15 });
  await page.keyboard.press('Enter');
}
async function recorder(page, dir) {
  fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(dir, { recursive: true });
  const cdp = await page.createCDPSession(); let n = 0;
  cdp.on('Page.screencastFrame', async f => { fs.writeFileSync(`${dir}/f${String(n++).padStart(4, '0')}.jpg`, Buffer.from(f.data, 'base64')); cdp.send('Page.screencastFrameAck', { sessionId: f.sessionId }).catch(() => {}); });
  await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 70, everyNthFrame: 1 });
  return async () => { await cdp.send('Page.stopScreencast'); return n; };
}
module.exports = { clickField, launch, instrument, open, nodes, find, clickLabel, login, recorder, sleep, OUT, BASE, enableSemantics };
// 実マウス操作で押下（move→down→up）
async function press(page, re, { role, nth = 0, wait = 1800 } = {}) {
  let list = [];
  for (let i = 0; i < 20 && !list.length; i++) { list = (await nodes(page)).filter(n => re.test(n.label) && (!role || n.role === role)); if (!list.length) await sleep(300); }
  const n = list[nth]; if (!n) throw new Error('not found: ' + re);
  await page.mouse.move(n.x + n.w / 2, n.y + n.h / 2); await sleep(150);
  await page.mouse.down(); await sleep(70); await page.mouse.up(); await sleep(wait);
  await enableSemantics(page);
  return n;
}
async function dump(page, title, max = 70) {
  const l = (await nodes(page)).filter(n => n.label.length > 0 && n.label.length < 60 && n.w < 1200 || (n.label.length>0&&n.h<80)).map(n => `${n.role[0] || '-'}:${n.label.replace(/\n/g, ' / ').slice(0, 48)}@${Math.round(n.x)},${Math.round(n.y)},${Math.round(n.w)}x${Math.round(n.h)}`);
  console.log('== ' + title + '\n' + [...new Set(l)].slice(0, max).join('\n'));
}
module.exports.press = press; module.exports.dump = dump;

// 戻る: Back ノードがあればそれを、なければ左上の戻る矢印の座標を実マウスで押す
async function back(page, wait = 1500) {
  const n = (await nodes(page)).find(n => n.role === 'button' && /^(Back|戻る)$/.test(n.label));
  const [x, y] = n ? [n.x + n.w / 2, n.y + n.h / 2] : [28, 28];
  await page.mouse.move(x, y); await sleep(120); await page.mouse.down(); await sleep(70); await page.mouse.up(); await sleep(wait);
  await enableSemantics(page); return !!n;
}
module.exports.back = back;
