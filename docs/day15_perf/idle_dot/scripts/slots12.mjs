// 検証用エミュレータのみ。slots を 12 件にする（既存2件 + 10件）
const today=new Date();const dk=`${today.getFullYear()}-${String(today.getMonth()+1).padStart(2,'0')}-${String(today.getDate()).padStart(2,'0')}`;
const str=s=>({stringValue:s});const iso=d=>({timestampValue:d.toISOString()});const inH=h=>new Date(Date.now()+h*3600e3);
const ids=['001','002','004','005','008','011','013','014','016','018'];
const sts=['open','filled','open','expired','open','filled','released','open','filled','open'];
for(let i=0;i<ids.length;i++){
 const id=`${dk}_dummy-c${ids[i]}`;
 const f={dateKey:str(dk),sourceAbsent:str('dummy-c'+ids[i]),status:str(sts[i]==='expired'?'open':sts[i]==='released'?'open':sts[i]),expiresAt:iso(sts[i]==='expired'?inH(-2):inH(3+i%3)),
  notifiedList:{arrayValue:{values:[str('dummy-c020'),str('dummy-c021')]}}};
 if(sts[i]==='filled')f.claimedBy={mapValue:{fields:{customerId:str('dummy-c03'+(i%9)),claimedAt:iso(inH(-1))}}};
 const r=await fetch(`http://127.0.0.1:8080/v1/projects/demo-linkday/databases/(default)/documents/slots/${encodeURIComponent(id)}`,{method:'PATCH',headers:{'content-type':'application/json',authorization:'Bearer owner'},body:JSON.stringify({fields:f})});
 if(!r.ok){console.log('fail',r.status);process.exit(1)}
}
console.log('ok 12 slots',dk);
