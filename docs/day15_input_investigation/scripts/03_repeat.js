const L = require('./lib2');
(async () => {
  let ok = 0;
  for (let i = 0; i < 6; i++) {
    const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
    let st = null; page.on('response', r => { if (r.url().includes('signInWithPassword') && r.request().method()==='POST') st = r.status(); });
    await L.open(page); await L.login(page); await L.sleep(3500);
    const home = (await L.nodes(page)).some(n => /ダッシュボード/.test(n.label));
    console.log('run', i, st, home); if (home) ok++;
    await b.close();
  }
  console.log('success', ok, '/ 6');
})();
