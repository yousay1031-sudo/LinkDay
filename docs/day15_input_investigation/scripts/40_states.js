const L = require('./lib2');
const W = process.argv[2]==='390' ? 390 : 1280; const vp = W===390?{width:390,height:844}:{width:1280,height:800};
const P = `${L.OUT}/s_${W}_`;
const ls = (page,k,v)=>page.evaluate((k,v)=>{ if(v===null) localStorage.removeItem('flutter.'+k); else localStorage.setItem('flutter.'+k, v); },k,v);
(async()=>{
 const b=await L.launch(); const page=await b.newPage(); await page.setViewport(vp);
 page.on('console', m=>{const t=m.text(); if(/verify\]|Exception|error/i.test(t)) console.log('c:',t.slice(0,160));});
 await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
 await page.screenshot({path:P+'home.png'});
 // 出席: 遅延 → スケルトン
 await ls(page,'verify_delay_ms','3000');
 await L.press(page,/^出席管理$/,{role:'button',wait:700});
 await page.screenshot({path:P+'att_a_skeleton.png'});
 await L.sleep(3500); await page.screenshot({path:P+'att_b_content.png'});
 await L.dump(page,'att after delay',12);
 await L.press(page,/^Back$/,{role:'button'});
 // 出席: エラー → 再試行
 await ls(page,'verify_delay_ms',null); await ls(page,'verify_faults','"attendance"');
 await L.press(page,/^出席管理$/,{role:'button',wait:2500});
 await page.screenshot({path:P+'att_c_error.png'});
 await L.dump(page,'att error',20);
 await ls(page,'verify_faults',null);
 await L.press(page,/再試行|もう一度|リトライ/,{wait:2500});
 await page.screenshot({path:P+'att_d_retry_ok.png'});
 await L.dump(page,'att retry ok',8);
 await b.close();
})().catch(e=>{console.log('ERR',e.message);process.exit(1)});
