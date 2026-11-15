const L = require('./lib2');
(async () => {
  const b = await L.launch(); const page = await b.newPage(); await page.setViewport({ width: 1280, height: 800 });
  page.on('console', m => { const t = m.text(); if (/VerifySeed|Startup|CustomerService|Attendance|HomeScreen|Verify\]/.test(t)) console.log('console:', t.slice(0, 200)); });
  await L.open(page);
  console.log('idb:', await page.evaluate(async () => { const dbs = await indexedDB.databases(); return JSON.stringify(dbs); }));
  await b.close();
})();
