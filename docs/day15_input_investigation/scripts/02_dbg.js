const L = require('./lib2');
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
  const t0 = Date.now();
  page.on('request', r => { if (r.url().includes('9099')) console.log(Date.now()-t0, 'REQ', r.method(), r.url().split('?')[0].split('/').slice(-1)[0], (r.postData()||'').length); });
  page.on('response', r => { if (r.url().includes('9099')) console.log(Date.now()-t0, 'RES', r.status(), r.url().split('?')[0].split('/').slice(-1)[0]); });
  await L.open(page);
  console.log(Date.now()-t0, 'opened');
  await L.login(page); await L.sleep(5000);
  console.log('labels:', (await L.nodes(page)).map(n=>n.label.slice(0,18)).filter(x=>x).slice(5,16).join(' | '));
  await page.screenshot({ path: L.OUT + '/dbg2.png' });
  await b.close();
})();
