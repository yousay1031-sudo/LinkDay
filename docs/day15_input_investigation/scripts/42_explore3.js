const L = require('./lib2');
const vp = process.argv[2]==='390' ? {width:390,height:844}:{width:1280,height:800};
(async()=>{
 const b=await L.launch(); const page=await b.newPage(); await page.setViewport(vp);
 page.on('console', m=>{const t=m.text(); if(/Exception|Error/.test(t)) console.log('c:',t.slice(0,200));});
 await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
 await L.press(page,/^顧客管理$/,{role:'button',wait:2500});
 await L.press(page,/^Excel一括インポート$/,{role:'button',wait:2000}); await page.screenshot({path:`${L.OUT}/tmp_import.png`}); await L.dump(page,'import',25);
 console.log("back via node:",await L.back(page));
 await L.press(page,/^送迎場所の位置確認$/,{role:'button',wait:2500}); await page.screenshot({path:`${L.OUT}/tmp_resolve.png`}); await L.dump(page,'resolve',40);
 console.log("back via node:",await L.back(page));
 await L.press(page,/^仮名 一郎/,{role:'button',wait:2500}); await page.screenshot({path:`${L.OUT}/tmp_edit.png`}); await L.dump(page,'edit',50);
 console.log("back via node:",await L.back(page)); console.log("back via node:",await L.back(page));
 await L.press(page,/^出席管理$/,{role:'button',wait:2500});
 await L.press(page,/^LINE通知の履歴$/,{role:'button',wait:2500}); await page.screenshot({path:`${L.OUT}/tmp_hist.png`}); await L.dump(page,'history',40);
 await b.close();
})().catch(e=>{console.log('ERR',e.message);process.exit(1)});
