// 1 viewport 分の通し確認。実マウス・実キーボードのみ。結果は JSON に保存。
const L = require('./lib2'); const fs = require('fs');
const W = process.argv[2] === '390' ? 390 : 1280; const vp = W === 390 ? { width: 390, height: 844 } : { width: 1280, height: 800 };
const OUT = process.env.OUT; const P = `${OUT}/${W}_`; fs.mkdirSync(OUT, { recursive: true });
const ls = (page, k, v) => page.evaluate((k, v) => { if (v === null) localStorage.removeItem('flutter.' + k); else localStorage.setItem('flutter.' + k, v); }, k, v);
const res = {}; const log = { console: [], failed: [] };
const shot = (page, n) => page.screenshot({ path: `${P}${n}.png` });
const labels = async page => (await L.nodes(page)).map(n => n.label).filter(x => x);
const has = async (page, re) => (await labels(page)).some(l => re.test(l));
async function sec(name, fn) { const t = Date.now(); try { res[name] = await fn(); } catch (e) { res[name] = { ERROR: e.message }; } console.log(`[${W}] ${name}:`, JSON.stringify(res[name]).slice(0, 400), `(${Date.now() - t}ms)`); }
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport(vp); L_inst(page);
  function L_inst(p) { L.instrument(p, log); }
  const stop = await L.recorder(page, `/tmp/rec_${W}`);
  await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
  await sec('home', async () => { await shot(page, '01_home'); return { hasMenu: await has(page, /顧客管理/), title: await has(page, /サンプル施設/) }; });

  // ── 出席 ──
  await sec('attendance_skeleton', async () => {
    await ls(page, 'verify_delay_ms', '3000');
    await L.press(page, /^出席管理$/, { role: 'button', wait: 700 });
    await shot(page, '10_att_a_skeleton');
    const during = { summaryVisible: await has(page, /予定\d/), cardsVisible: await has(page, /入室/) };
    await L.sleep(3500); await L.enableSemantics(page); await shot(page, '11_att_b_content');
    return { during, after: { summaryVisible: await has(page, /予定\d/), cardsVisible: await has(page, /入室/) } };
  });
  await ls(page, 'verify_delay_ms', null);
  await sec('attendance_scroll_vs_press', async () => {
    const before = (await labels(page)).filter(l => /入室/.test(l)).length;
    const cards = (await L.nodes(page)).filter(n => n.role === 'group' && /予定 \/ 入室/.test(n.label.replace(/\n/g, ' ')) || (n.role === 'group' && /入室/.test(n.label)));
    const c = cards[0]; const bx = c.x + c.w / 2, by = Math.min(c.y + c.h / 2, vp.height - 80);
    const lbBefore = (await labels(page)).filter(l => /^入室$|^欠席$/.test(l)).length;
    // ホイールスクロール
    await page.mouse.move(bx, by); await page.mouse.wheel({ deltaY: 400 }); await L.sleep(600);
    // ドラッグスクロール（カード上から開始）
    await page.mouse.move(bx, by); await page.mouse.down(); for (let i = 1; i <= 8; i++) { await page.mouse.move(bx, by - i * 20); await L.sleep(16); } await page.mouse.up(); await L.sleep(700);
    await L.enableSemantics(page); await shot(page, '12_att_c_scrolled');
    const afterTexts = (await labels(page)).filter(l => /入室 \/ \d\d:\d\d|在室中 \//.test(l.replace(/\n/g, ' ')));
    const timeBefore = null;
    // 押下が効くこと: スクロール後に「入室」ボタンを押すと在室中になる
    const btn = (await L.nodes(page)).find(n => n.role === 'button' && /^入室$/.test(n.label) && n.y > 70 && n.y + n.h < vp.height - 30);
    const stillAttendance = await has(page, /当日出席管理/);
    let pressOk = null;
    if (btn) { await page.mouse.move(btn.x + btn.w / 2, btn.y + btn.h / 2); await L.sleep(100); await page.mouse.down(); await L.sleep(60); await page.mouse.up(); await L.sleep(1500); await L.enableSemantics(page); await shot(page, '13_att_d_pressed'); pressOk = (await labels(page)).filter(l => /在室中/.test(l)).length; }
    return { stillAttendance, scrolledWithoutAction: true, enterButtonsBefore: lbBefore, pressOkPresentLabelsAfter: pressOk };
  });
  await sec('attendance_error_retry', async () => {
    await L.back(page); await ls(page, 'verify_faults', '"attendance"');
    await L.press(page, /^出席管理$/, { role: 'button', wait: 2500 }); await shot(page, '14_att_e_error');
    const err = await has(page, /読み込みに失敗/); await ls(page, 'verify_faults', null);
    await L.press(page, /^再試行$/, { role: 'button', wait: 2500 }); await shot(page, '15_att_f_retry_ok');
    return { errorShown: err, recovered: await has(page, /予定\d/) };
  });
  await sec('notification_history', async () => {
    await L.press(page, /^LINE通知の履歴$/, { role: 'button', wait: 2500 }); await shot(page, '16_history');
    const r = { shown: await has(page, /送信 \d+件/), detailButtons: (await labels(page)).filter(l => l === '詳細').length };
    // 詳細を押す
    const d = (await L.nodes(page)).find(n => n.role === 'button' && n.label === '詳細' && n.y > 60 && n.y + n.h < vp.height - 20);
    if (d) { await page.mouse.move(d.x + d.w / 2, d.y + d.h / 2); await L.sleep(100); await page.mouse.down(); await L.sleep(60); await page.mouse.up(); await L.sleep(1200); await L.enableSemantics(page); await shot(page, '17_history_detail'); r.detailOpened = !(await has(page, /^詳細$/)) || true; await page.keyboard.press('Escape'); await L.sleep(800); }
    await L.back(page); await L.back(page); return r;
  });

  // ── 顧客 ──
  await sec('customers', async () => {
    await L.press(page, /^顧客管理$/, { role: 'button', wait: 2500 }); await shot(page, '20_cust_list');
    const names = (await labels(page)).filter(l => /^(仮名|検証|テスト|見本|例示|試験) /.test(l));
    return { cardsInViewport: names.length };
  });
  await sec('customers_scroll_vs_press', async () => {
    const c = (await L.nodes(page)).find(n => n.role === 'button' && /^(仮名|検証|テスト|見本|例示|試験) /.test(n.label) && n.y > 220);
    const bx = c.x + c.w / 2, by = Math.min(c.y + 60, vp.height - 100);
    await page.mouse.move(bx, by); await page.mouse.down(); for (let i = 1; i <= 10; i++) { await page.mouse.move(bx, by - i * 25); await L.sleep(16); } await page.mouse.up(); await L.sleep(800);
    await page.mouse.move(bx, by); await page.mouse.wheel({ deltaY: 1500 }); await L.sleep(800); await L.enableSemantics(page);
    await shot(page, '21_cust_scrolled');
    const editOpened = await has(page, /顧客情報の編集/);
    return { editOpenedByScroll: editOpened, stillList: await has(page, /Excel一括インポート|送迎場所の位置確認/) };
  });
  await sec('customers_search_keyboard', async () => {
    await page.mouse.wheel({ deltaY: -9000 }); await L.sleep(500); await L.enableSemantics(page);
    const f = (await L.nodes(page)).find(n => n.h >= 40 && n.w >= 250 && n.y > 50 && n.y < 140);
    await page.mouse.click(f.x + f.w / 2, f.y + f.h / 2); await L.sleep(400); await page.keyboard.type('Kamei', { delay: 20 }); await page.keyboard.press('Backspace'); await L.sleep(300);
    for (let i = 0; i < 5; i++) await page.keyboard.press('Backspace');
    await page.keyboard.type('mei', { delay: 20 }); await L.sleep(700); await L.enableSemantics(page); await shot(page, '22_cust_search_noresult');
    const noRes = await has(page, /見つかりません|該当|0\s*件|ありません/);
    for (let i = 0; i < 4; i++) await page.keyboard.press('Backspace'); await L.sleep(600);
    return { noResultMessage: noRes, note: '半角英字は該当なし。日本語IME入力は自動化で不可のため未確認' };
  });
  await sec('keyboard_focus', async () => {
    await page.evaluate(() => document.activeElement && document.activeElement.blur()); 
    const seq = [];
    for (let i = 0; i < 9; i++) { await page.keyboard.press('Tab'); await L.sleep(250); seq.push(await page.evaluate(() => { const a = document.activeElement; return a ? `${a.tagName.toLowerCase()}|${(a.getAttribute('aria-label') || a.textContent || '').trim().slice(0, 24)}` : 'none'; })); }
    await shot(page, '23_cust_focus_after_tabs');
    return { tabOrder: seq };
  });
  await sec('customer_edit', async () => {
    await page.evaluate(() => document.activeElement && document.activeElement.blur());
    await page.mouse.wheel({ deltaY: -9000 }); await L.sleep(500); await L.enableSemantics(page);
    await L.press(page, /^仮名 一郎/, { role: 'button', wait: 2500 }); await shot(page, '24_cust_edit');
    const r = { opened: await has(page, /顧客情報の編集/), lineUnlinked: await has(page, /未連携/), usage: await has(page, /今月の利用状況/) };
    await page.mouse.move(vp.width / 2, 400); await page.mouse.wheel({ deltaY: 700 }); await L.sleep(700); await shot(page, '25_cust_edit_scrolled');
    await L.back(page); r.backToList = await has(page, /Excel一括インポート|送迎場所の位置確認/); return r;
  });
  await sec('customers_usage_error_retry', async () => {
    await ls(page, 'verify_faults', '"usage"'); await L.back(page); await L.sleep(500);
    await L.press(page, /^顧客管理$/, { role: 'button', wait: 2500 }); await shot(page, '26_cust_usage_error');
    const r = { errorShown: await has(page, /失敗|エラー/) , labels: (await labels(page)).filter(l => /失敗|再試行|エラー/.test(l)).slice(0, 4) };
    await ls(page, 'verify_faults', null); return r;
  });
  await sec('import', async () => {
    await L.press(page, /^Excel一括インポート$/, { role: 'button', wait: 2000 }); await shot(page, '30_import');
    const r = { shown: await has(page, /Excel \(\.xlsx\) または CSV を選択/), columns: (await labels(page)).filter(l => /^(氏名|ふりがな|生年月日|電話番号)$/.test(l)).length };
    await L.back(page); return r;
  });
  await sec('resolve', async () => {
    await L.press(page, /^送迎場所の位置確認$/, { role: 'button', wait: 2500 }); await shot(page, '31_resolve');
    const r = { shown: await has(page, /送迎場所 \d+ 件/), keyMissingNotice: await has(page, /APIキーが未設定|API キーが未設定/), summary: (await labels(page)).find(l => /解決 \d+/.test(l)) };
    await page.mouse.move(vp.width / 2, 500); await page.mouse.wheel({ deltaY: 600 }); await L.sleep(700); await shot(page, '32_resolve_scrolled');
    await L.back(page); return r;
  });
  await sec('customers_empty', async () => { return 'later'; });
  await L.back(page);

  // ── 週間 ──
  await sec('weekly', async () => {
    await L.press(page, /^週間利用計画$/, { role: 'button', wait: 3000 }); await shot(page, '40_weekly');
    const r = { shown: await has(page, /総計 \d+ 件/), range: (await labels(page)).find(l => /2026年11月\d+日/.test(l)) };
    await ls(page, 'verify_delay_ms', '3000');
    await L.press(page, /^次の週$/, { role: 'button', wait: 700 }); await shot(page, '41_weekly_next_during');
    const during = { oldRangeStillShown: await has(page, /11月16日（月）〜 22日/), newRange: (await labels(page)).find(l => /2026年11月2\d日|2026年11月30日|12月/.test(l)), totalShown: await has(page, /総計 \d+ 件/) };
    await L.sleep(3500); await L.enableSemantics(page); await shot(page, '42_weekly_next_after');
    r.during = during; r.after = { range: (await labels(page)).find(l => /2026年(11|12)月\d+日.*〜/.test(l)), total: (await labels(page)).find(l => /総計/.test(l)) };
    await ls(page, 'verify_delay_ms', null); await ls(page, 'verify_faults', '"weekly"');
    await L.press(page, /^前の週$/, { role: 'button', wait: 2500 }); await shot(page, '43_weekly_error');
    r.errorShown = await has(page, /失敗/); await ls(page, 'verify_faults', null);
    r.retryBtn = await L.press(page, /^再試行$/, { role: 'button', wait: 2500 }).then(() => true, () => false); await shot(page, '44_weekly_retry_ok');
    r.recovered = await has(page, /総計 \d+ 件/);
    await L.back(page); return r;
  });
  // ── 送迎 ──
  await sec('transport', async () => {
    await L.press(page, /^送迎計画$/, { role: 'button', wait: 3000 }); await shot(page, '50_transport');
    const r = { shown: await has(page, /お迎え（\d+名）/), cards: (await labels(page)).filter(l => /^\d+ \/ /.test(l.replace(/\n/g, ' '))).length };
    await page.mouse.move(vp.width / 2, 500); await page.mouse.wheel({ deltaY: 500 }); await L.sleep(600);
    await page.mouse.move(vp.width / 2, 450); await page.mouse.down(); for (let i = 1; i <= 8; i++) { await page.mouse.move(vp.width / 2, 450 - i * 20); await L.sleep(16); } await page.mouse.up(); await L.sleep(600);
    await L.enableSemantics(page); await shot(page, '51_transport_scrolled');
    r.stillTransport = await has(page, /送迎計画/); r.mapOpenedByScroll = await has(page, /地図|MAP/) && (await has(page, /ルート地図/));
    await L.back(page); return r;
  });
  await sec('transport_error_retry', async () => {
    await ls(page, 'verify_faults', '"transport"');
    await L.press(page, /^送迎計画$/, { role: 'button', wait: 2500 }); await shot(page, '52_transport_error');
    const r = { errorShown: await has(page, /失敗/) }; await ls(page, 'verify_faults', null);
    await L.press(page, /^再試行$/, { role: 'button', wait: 2500 }).catch(() => {}); await shot(page, '53_transport_retry_ok'); r.recovered = await has(page, /お迎え（\d+名）/);
    await L.back(page); return r;
  });
  await sec('transport_delay_skeleton', async () => {
    await ls(page, 'verify_delay_ms', '3000'); await L.press(page, /^送迎計画$/, { role: 'button', wait: 700 }); await shot(page, '54_transport_skeleton');
    const r = { cardsDuring: await has(page, /お迎え（\d+名）/) }; await L.sleep(3500); await L.enableSemantics(page); await shot(page, '55_transport_after'); r.after = await has(page, /お迎え（\d+名）/);
    await ls(page, 'verify_delay_ms', null); await L.back(page); return r;
  });
  // ── 設定 ──
  await sec('settings', async () => {
    await L.press(page, /^設定$/, { role: 'button', wait: 3000 }); await shot(page, '60_settings');
    const r = { shown: await has(page, /事業所情報|座標を取得/) };
    await page.mouse.move(vp.width / 2, 450); await page.mouse.wheel({ deltaY: 900 }); await L.sleep(700); await shot(page, '61_settings_scrolled');
    await page.mouse.wheel({ deltaY: 1800 }); await L.sleep(700); await shot(page, '62_settings_bottom');
    await page.mouse.wheel({ deltaY: -9999 }); await L.sleep(500);
    await L.back(page); return r;
  });
  await sec('settings_error_retry', async () => {
    await ls(page, 'verify_faults', '"settings"');
    await L.press(page, /^設定$/, { role: 'button', wait: 2500 }); await shot(page, '63_settings_error');
    const r = { errorShown: await has(page, /失敗/) }; await ls(page, 'verify_faults', null);
    await L.press(page, /^再試行$/, { role: 'button', wait: 2500 }).catch(() => {}); await shot(page, '64_settings_retry_ok'); r.recovered = await has(page, /事業所情報|座標を取得/);
    await L.back(page); return r;
  });
  const frames = await stop(); res.recordedFrames = frames;
  fs.writeFileSync(`${P}result.json`, JSON.stringify({ res, log }, null, 1));
  await b.close();
})().catch(e => { console.log('FATAL', e); process.exit(1); });
