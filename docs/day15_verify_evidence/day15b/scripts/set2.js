const L = require('./lib2'); const fs = require('fs');
const W = +process.argv[2]; const vp = W === 390 ? { width: 390, height: 844 } : { width: 1280, height: 800 };
const OUT = '/home/user/flutter_app/docs/day15_verify_evidence/day15b';
const ls = (page, k, v) => page.evaluate((k, v) => { if (v === null) localStorage.removeItem('flutter.' + k); else localStorage.setItem('flutter.' + k, v); }, k, v);
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport(vp);
  await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
  const get = async () => (await L.nodes(page));
  const state = async () => { const ns = await get(); const f = (re, role) => ns.find(n => re.test(n.label || '') && (!role || n.role === role));
    const en = n => !!n; return { msg: !!ns.find(n => n.label === 'APIキーを読み込めませんでした'), retry: !!f(/^再試行$/, 'button'), save: !!f(/^保存$/, 'button'), clear: !!f(/^クリア$/, 'button') }; };
  const scrollDown = async () => { for (let i = 0; i < 14; i++) { await page.mouse.move(vp.width/2, 450); await page.mouse.wheel({ deltaY: 350 }); await L.sleep(250); } await L.sleep(500); await L.enableSemantics(page); };
  const res = { vp };
  await ls(page, 'verify_faults', '"settings"');
  await L.press(page, /^設定$/, { role: 'button', wait: 2500 });
  await scrollDown();
  res.error = await state();
  await page.screenshot({ path: `${OUT}/after_${W}_65_settings_error_scrolled.png` });
  // 読込失敗中: 保存・クリアを実マウスで押す（無効のはず）
  const ns = await get();
  for (const lab of ['保存', 'クリア']) { const n = ns.find(x => x.label === lab && x.role === 'button'); if (n) { await page.mouse.move(n.x + n.w / 2, n.y + n.h / 2); await page.mouse.down(); await page.mouse.up(); await L.sleep(600); } }
  await L.enableSemantics(page);
  res.afterClickOnDisabled = { dialogShown: (await get()).some(n => /APIキーをクリア|削除しますか/.test(n.label || '')), snack: (await get()).some(n => /保存しました|削除しました|入力してください/.test(n.label || '')) };
  await page.screenshot({ path: `${OUT}/after_${W}_65b_after_click_disabled.png` });
  await ls(page, 'verify_faults', null);
  await L.press(page, /^再試行$/, { role: 'button', wait: 2500 });
  await L.enableSemantics(page);
  res.recovered = await state();
  await page.screenshot({ path: `${OUT}/after_${W}_66_settings_retry_recovered.png` });
  fs.writeFileSync(`${OUT}/after_${W}_settings_error_result.json`, JSON.stringify(res, null, 1));
  console.log(JSON.stringify(res));
  await b.close();
})();
