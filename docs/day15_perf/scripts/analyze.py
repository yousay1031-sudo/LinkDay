import json,glob,statistics as st,sys,os
O='/home/user/day15_verify/v4/bench'
IDLE=300  # ms: これ以上フレームが出なければ「描画が静止した」とみなす
def pct(a,p):
    a=sorted(a); 
    if not a: return None
    k=(len(a)-1)*p; f=int(k); c=min(f+1,len(a)-1); return a[f]+(a[c]-a[f])*(k-f)
def analyze(path):
    d=json.load(open(path)); raw=d['raw']
    fr=sorted([f for f in raw['frames'] if f[0]=='Frame'],key=lambda f:f[1])
    lt=raw['lt']; res={}
    for o in d['ops']:
        n=o['name']; ev=o['ev']
        if n=='B': t0=ev[0][2]; tl=ev[-1][2]; win_end=tl+1000   # 最初のwheel〜最後のwheel+1s
        else: t0=ev[0][2]; tl=t0; win_end=t0+3000
        w=[f for f in fr if t0<=f[1]<=win_end]
        durs=[f[2] for f in w]
        # 静止時刻: t0 以降、次のフレームまでの間隔が IDLE 以上になる最初のフレーム（操作終了後）
        settle=None
        for i,f in enumerate(w):
            if f[1]<tl: continue
            nxt=w[i+1][1] if i+1<len(w) else win_end+IDLE
            if nxt-f[1]>=IDLE: settle=f[1]+f[2]-t0; break
        heavy=[f for f in w if f[2]>16.7]
        heavy_end=round(heavy[-1][1]+heavy[-1][2]-t0) if heavy else None
        busy_after=[f for f in w if f[1]>=t0+1500]
        gaps=[w[i+1][1]-w[i][1] for i in range(len(w)-1)]
        act=[g for i,g in enumerate(gaps) if w[i][1]<=tl+ (0 if n!='B' else 0) or n!='B']
        # B はスクロール区間内だけでフレーム間隔を見る
        if n=='B':
            ws=[f for f in w if f[1]<=tl]; gaps=[ws[i+1][1]-ws[i][1] for i in range(len(ws)-1)]; durs_act=[f[2] for f in ws]
        else: durs_act=durs
        ltw=[l for l in lt if t0-1<=l[0]<=win_end]
        res[n]={'frames':len(w),'frame_ms_sum':round(sum(durs),1),'frame_ms_max':round(max(durs),1) if durs else None,'frame_ms_p95':round(pct(durs,.95),1) if durs else None,
            'frames_gt16_7':sum(1 for x in durs_act if x>16.7),'frames_gt33':sum(1 for x in durs_act if x>33.3),'frames_gt50':sum(1 for x in durs_act if x>50),
            'gap_max':round(max(gaps),1) if gaps else None,'gaps_gt50':sum(1 for g in gaps if g>50),
            'longtasks':len(ltw),'longtask_ms':round(sum(l[1] for l in ltw)),'longtask_max':round(max([l[1] for l in ltw]+[0])),
            'heavy_end_ms':heavy_end,'frames_after_1500ms':len(busy_after),'settle_ms':round(settle) if settle is not None else None,'nwheel':len(ev) if n=='B' else None,'scroll_span_ms':round(tl-t0) if n=='B' else None}
    return d['meta'],res
out={}
for p in sorted(glob.glob(O+'/*_raw.json')):
    m,r=analyze(p); out[f"{m['cond']}{m['run']}"]=dict(meta=m,res=r)
json.dump(out,open('/home/user/day15_verify/v4/bench_analysis.json','w'),indent=1)
keys=['heavy_end_ms','frames_after_1500ms','settle_ms','frames','frame_ms_sum','frame_ms_max','frames_gt16_7','frames_gt33','gap_max','gaps_gt50','longtasks','longtask_ms','longtask_max']
for op in 'ACB':
    print('=== op',op)
    for k in keys:
        row=[]
        for c in ['motion','reduce']:
            v=[out[f'{c}{r}']['res'][op][k] for r in (1,2,3) if f'{c}{r}' in out and out[f'{c}{r}']['res'][op][k] is not None]
            row.append(f"{c}: {v} med={st.median(v) if v else None}")
        print(f"  {k:15s}"," | ".join(row))
