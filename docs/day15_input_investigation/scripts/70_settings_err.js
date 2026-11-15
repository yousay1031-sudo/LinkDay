const L = require('./lib2'); const fs = require('fs');
const OUT = '/home/user/flutter_app/docs/day15_verify_evidence';
const W = process.argv[2] === '390' ? 390 : 1280; const vp = W === 390 ? { width: 390, height: 844 } : { width: 1280, height: 800 };
const ls = (page, k, v) => page.evaluate((k, v) => { if (v === null) localStorage.removeItem('flutter.' + k); else localStorage.setItem('flutter.' + k, v); }, k, v);
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport(vp);
  const logs = []; page.on('console', m => { if (/SettingsScreen|verify\]/.test(m.text())) logs.push(m.text().slice(0, 140)); });
  await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
  const labels = async () => (await L.nodes(page)).map(n => n.label).filter(x => x);
  const scrollTo = async (re) => { for (let i = 0; i < 14; i++) { if ((await labels()).some(l => re.test(l)) ) { const n = (await L.nodes(page)).find(n => re.test(n.label)); if (n && n.y > 60 && n.y < vp.height - 80) return n; } await page.mouse.move(vp.width / 2, 450); await page.mouse.wheel({ deltaY: 350 }); await L.sleep(350); await L.enableSemantics(page); } return null; };
  const res = {};
  // 故障注入あり
  await ls(page, 'verify_faults', '"settings"');
  await L.press(page, /^設定$/, { role: 'button', wait: 2500 });
  res.faultReached = logs.some(l => /loadJsApiKey failed/.test(l)); res.logs = [...logs];
  res.topHasFailText = (await labels()).some(l => /失敗|読み込めません/.test(l));
  const n = await scrollTo(/読み込めませんでした|読み込みに失敗/);
  res.errorFoundAfterScroll = !!n; res.errorLabel = n && n.label;
  await page.screenshot({ path: `${OUT}/${W}_65_settings_error_scrolled.png` });
  res.retryBtn = !!(await L.nodes(page)).find(x => x.role === 'button' && /再試行/.test(x.label));
  // 注入解除 → 再試行
  await ls(page, 'verify_faults', null);
  const r = await L.press(page, /^再試行$/, { role: 'button', wait: 2500 }).then(() => true, e => e.message);
  res.retryPressed = r; await page.screenshot({ path: `${OUT}/${W}_66_settings_retry_recovered.png` });
  res.afterRetry = { errorGone: !(await labels()).some(l => /読み込めませんでした|読み込みに失敗/.test(l)), apiKeyFieldShown: (await labels()).some(l => /API キー/.test(l)) };
  res.logsAfter = logs.slice(-3);
  console.log(JSON.stringify(res, null, 1)); fs.writeFileSync(`${OUT}/${W}_settings_error_result.json`, JSON.stringify(res, null, 1));
  await b.close();
})().catch(e => { console.log('FATAL', e.message); process.exit(1); });
