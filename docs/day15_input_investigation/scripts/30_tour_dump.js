const L = require('./lib2');
const vp = process.argv[2]==='390' ? {width:390,height:844}:{width:1280,height:800};
async function press(page, re, role){ const list=(await L.nodes(page)).filter(n=>re.test(n.label)&&(!role||n.role===role)); const n=list[0]; if(!n) throw new Error('nf '+re); await page.mouse.move(n.x+n.w/2,n.y+n.h/2); await L.sleep(150); await page.mouse.down(); await L.sleep(70); await page.mouse.up(); await L.sleep(1800); L.enableSemantics&&0; return n;}
(async()=>{
 const b=await L.launch(); const page=await b.newPage(); await page.setViewport(vp);
 await L.open(page); await L.login(page); await L.sleep(3500); await L.enableSemantics(page);
 const dump=async t=>{console.log('==',t); console.log((await L.nodes(page)).map(n=>`${n.role[0]||'-'}:${n.label.replace(/\n/g,' / ').slice(0,50)}@${Math.round(n.x)},${Math.round(n.y)},${Math.round(n.w)}x${Math.round(n.h)}`).filter(x=>x.length>12).slice(0,60).join('\n'));};
 await dump('home');
 await b.close();
})();
