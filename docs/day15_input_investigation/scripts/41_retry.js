const L = require('./lib2');
const ls = (page,k,v)=>page.evaluate((k,v)=>{ if(v===null) localStorage.removeItem('flutter.'+k); else localStorage.setItem('flutter.'+k, v); },k,v);
(async()=>{
 const b=await L.launch(); const page=await b.newPage(); await page.setViewport({width:1280,height:800});
 page.on('console', m=>{const t=m.text(); if(/verify\]|AttendanceScreen|Exception/i.test(t)) console.log('c:',t.slice(0,160));});
 await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
 await ls(page,'verify_faults','"attendance"');
 console.log(await page.evaluate(()=>JSON.stringify(Object.entries(localStorage).filter(([k])=>/verify/.test(k)))));
 await L.press(page,/^出席管理$/,{role:'button',wait:2500});
 await ls(page,'verify_faults',null);
 console.log(await page.evaluate(()=>JSON.stringify(Object.entries(localStorage).filter(([k])=>/verify/.test(k)))));
 const n=await L.press(page,/^再試行$/,{role:'button',wait:3000}); console.log(JSON.stringify(n));
 await L.dump(page,'after',10);
 await b.close();
})();
