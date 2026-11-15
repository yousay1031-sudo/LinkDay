const L = require('./lib2');
const vp = process.argv[2]==='390' ? {width:390,height:844}:{width:1280,height:800};
(async()=>{
 const b=await L.launch(); const page=await b.newPage(); await page.setViewport(vp);
 page.on('console', m=>{const t=m.text(); if(/Exception|Error|error/.test(t)) console.log('c:',t.slice(0,200));});
 await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
 await L.press(page,/^顧客管理$/,{role:'button'});
 await page.screenshot({path:`${L.OUT}/tmp_cust.png`});
 await L.dump(page,'customers',80);
 await b.close();
})();
