const L = require('./lib2'); const fs=require('fs');
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 390, height: 844 });
  console.log('version', await b.version(), await page.evaluate(()=>navigator.userAgent));
  await L.open(page); await L.login(page); await L.sleep(3500);
  const info = await page.evaluate(() => { const c=document.createElement('canvas'); const gl=c.getContext('webgl2')||c.getContext('webgl'); let r=null; if(gl){const e=gl.getExtension('WEBGL_debug_renderer_info'); r={vendor:e?gl.getParameter(e.UNMASKED_VENDOR_WEBGL):gl.getParameter(gl.VENDOR), renderer:e?gl.getParameter(e.UNMASKED_RENDERER_WEBGL):gl.getParameter(gl.RENDERER), version:gl.getParameter(gl.VERSION)};} return {webgl:r, dpr:devicePixelRatio, hc:navigator.hardwareConcurrency, mem:navigator.deviceMemory, inner:[innerWidth,innerHeight], canvasKit:!!window.flutterCanvasKit, variant:window.flutterConfiguration||null, measures:performance.getEntriesByType('measure').length, marks:performance.getEntriesByType('mark').length, scripts:[...document.scripts].map(s=>s.src).filter(Boolean)}; });
  console.log(JSON.stringify(info));
  const g = await b.newPage(); await g.goto('chrome://gpu'); await L.sleep(2500);
  const txt = await g.evaluate(() => document.body.innerText);
  fs.writeFileSync('/home/user/day15_verify/v4/chrome_gpu.txt', txt);
  console.log(txt.split('\n').filter(l=>/Canvas:|Compositing|Rasterization|WebGL|Skia Graphite|GL_RENDERER|Vulkan|ANGLE|Software|Hardware accel|Disabled|Graphics Feature/i.test(l)).slice(0,40).join('\n'));
  const cdp = await page.createCDPSession(); const si = await b.target().createCDPSession().then(s=>s.send('SystemInfo.getInfo').catch(e=>String(e)));
  console.log(JSON.stringify(si).slice(0,1500));
  await b.close();
})();
