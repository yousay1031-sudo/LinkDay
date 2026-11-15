const { launch, instrument, URL, OUT } = require('./lib');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const { execSync } = require('child_process');
(async () => {
  for (const [w, h] of (process.argv[2]==='390'?[[390,844]]:[[1280, 800], [390, 844]])) {
    const browser = await launch(); const page = await browser.newPage();
    await page.setViewport({ width: w, height: h });
    const log = { console: [], failed: [] }; instrument(page, log);
    await page.goto(URL); await page.waitForFunction(() => !document.getElementById('ld-boot'), { timeout: 60000 }); await sleep(1500);
    const btnY = w > 800 ? 571 : 593, linkY = w > 800 ? 627 : 649;
    const S = n => page.screenshot({ path: `${OUT}/6x_${w}_${n}.png` });
    // パスワード再設定ダイアログ（送信はしない）
    await page.mouse.click(w / 2, linkY); await sleep(250); await S('a_dialog_opening'); await sleep(700); await S('b_dialog_open');
    // ダイアログ内 Tab フォーカス
    const tabs = []; for (let i = 0; i < 4; i++) { await page.keyboard.press('Tab'); await sleep(250); tabs.push(await page.evaluate(() => document.activeElement?.tagName + (document.activeElement?.type ? '[' + document.activeElement.type + ']' : ''))); }
    await S('c_dialog_tab'); console.log(w, 'dialog tabs', tabs);
    await page.keyboard.press('Escape'); await sleep(700); await S('d_after_escape');
    const cancel = w > 800 ? [772, 464] : [282, 510]; await page.mouse.click(cancel[0], cancel[1]); await sleep(250); await S('d2_closing'); await sleep(700); await S('d3_after_cancel');
    // 押下縮小: 通常 → 実行中に reduce へ切替 → 再押下
    const crop = async name => { await page.screenshot({ path: `/tmp/${name}.png`, clip: { x: 0, y: btnY - 40, width: w, height: 80 } }); };
    // ダイアログが閉じていなければキャンセルボタンを探す必要があるので状態だけ記録
    await page.mouse.move(w / 2, btnY + 10); await page.mouse.down(); await sleep(250); await crop(`p_${w}_normal_down`); await page.mouse.move(w / 2, btnY + 200, { steps: 5 }); await page.mouse.up(); await sleep(400);
    await page.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }]); await sleep(500);
    await page.mouse.move(w / 2, btnY + 10); await page.mouse.down(); await sleep(250); await crop(`p_${w}_reduce_down`); await page.mouse.move(w / 2, btnY + 200, { steps: 5 }); await page.mouse.up(); await sleep(400);
    await crop(`p_${w}_idle`);
    await page.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'no-preference' }]); await sleep(500);
    await page.mouse.move(w / 2, btnY + 10); await page.mouse.down(); await sleep(250); await crop(`p_${w}_back_down`); await page.mouse.move(w / 2, btnY + 200, { steps: 5 }); await page.mouse.up(); await sleep(400);
    const diff = (a, b) => execSync(`compare -metric AE /tmp/${a}.png /tmp/${b}.png null: 2>&1 || true`).toString().trim();
    console.log(w, 'pixels differ vs idle: normal_down=', diff(`p_${w}_normal_down`, `p_${w}_idle`), 'reduce_down=', diff(`p_${w}_reduce_down`, `p_${w}_idle`), 'back_down=', diff(`p_${w}_back_down`, `p_${w}_idle`));
    execSync(`convert /tmp/p_${w}_idle.png /tmp/p_${w}_normal_down.png /tmp/p_${w}_reduce_down.png /tmp/p_${w}_back_down.png -append ${OUT}/6x_${w}_e_press_idle_normal_reduce_back.png`);
    console.log(w, 'log', JSON.stringify(log.console));
    await browser.close();
  }
})();
