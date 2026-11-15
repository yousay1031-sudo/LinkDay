const L = require('./lib2'); const fs=require('fs');
(async()=>{const b=await L.launch();const s=await b.target().createCDPSession();const si=await s.send('SystemInfo.getInfo');
const o={gpu:{devices:si.gpu.devices,driverBugWorkarounds:si.gpu.driverBugWorkarounds&&si.gpu.driverBugWorkarounds.length,featureStatus:si.gpu.featureStatus,videoDecoding:undefined,auxAttributes:{displayType:si.gpu.auxAttributes.displayType,glRenderer:si.gpu.auxAttributes.glRenderer,glVendor:si.gpu.auxAttributes.glVendor,glVersion:si.gpu.auxAttributes.glVersion}},modelName:si.modelName,commandLine:si.commandLine};
fs.writeFileSync('sysinfo.json',JSON.stringify(o,null,1));console.log(JSON.stringify(o.gpu.featureStatus),o.gpu.auxAttributes, o.commandLine.slice(0,400));await b.close();})();
