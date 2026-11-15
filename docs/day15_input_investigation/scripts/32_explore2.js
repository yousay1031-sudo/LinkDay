const L = require('./lib2');
const vp = process.argv[2]==='390' ? {width:390,height:844}:{width:1280,height:800};
const back = async page => { await L.press(page,/^Back$/,{role:'button'}); };
(async()=>{
 const b=await L.launch(); const page=await b.newPage(); await page.setViewport(vp);
 page.on('console', m=>{const t=m.text(); if(/Exception|Error/.test(t)) console.log('c:',t.slice(0,200));});
 await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
 for (const [name,re] of [['weekly',/^週間利用計画$/],['transport',/^送迎計画$/]]) {
   await L.press(page,re,{role:'button',wait:3000});
   await page.screenshot({path:`${L.OUT}/tmp_${name}.png`}); await L.dump(page,name,45); await back(page); await L.sleep(1200);
 }
 await L.press(page,/^設定$/,{role:'button',wait:3000}); await page.screenshot({path:`${L.OUT}/tmp_settings.png`}); await L.dump(page,'settings',45); await back(page);
 await L.press(page,/^出席管理$/,{role:'button',wait:3000}); await page.screenshot({path:`${L.OUT}/tmp_att.png`}); await L.dump(page,'attendance',60);
 await b.close();
})();
