const L = require('./lib2');
const dump = async (page, tag) => { const ns = await L.nodes(page); console.log('--', tag); console.log(ns.filter(n => n.label && n.w < 1200).map(n => `${n.role}|${n.label.slice(0, 30)}|${Math.round(n.x)},${Math.round(n.y)} ${Math.round(n.w)}x${Math.round(n.h)}`).slice(0, 45).join('\n')); };
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
  await L.open(page); await L.login(page); await L.sleep(3500);
  await L.enableSemantics(page);
  for (const [re, tag] of [[/出席管理/, 'attendance'], [/顧客管理/, 'customers']]) {
    await L.clickLabel(page, re); await L.sleep(2500); await L.enableSemantics(page);
    await dump(page, tag); await page.screenshot({ path: `${L.OUT}/20_${tag}.png` });
    await page.keyboard.press('Escape'); await L.sleep(300);
    const back = await L.find(page, /戻る|Back/i); if (back) { await page.mouse.click(back.x + back.w / 2, back.y + back.h / 2); await L.sleep(1200); } else { await page.goBack().catch(()=>{}); }
  }
  await b.close();
})();
