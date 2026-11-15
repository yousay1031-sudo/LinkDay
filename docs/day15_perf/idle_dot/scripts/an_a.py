import json,glob,sys,statistics as st
D=sys.argv[1]
def load(p):
    d=json.load(open(p)); raw=d['raw']; m=d['meta']
    fr=sorted([f for f in raw['frames'] if f[0]=='Frame'],key=lambda f:f[1])
    A=[o for o in d['ops'] if o['name']=='A'][0]; t0=A['ev'][0][2]
    w=[f for f in fr if t0<=f[1]<=t0+3000]
    def sub(name): return sorted([f for f in raw['frames'] if f[0]==name and t0<=f[1]<=t0+3000],key=lambda f:f[1])
    i0,i1=m['idle']; idle=[f for f in fr if i0<=f[1]<=i1]
    il=[l for l in raw['lt'] if i0<=l[0]<=i1]
    r={'A_frames':len(w),'A_gt16':sum(f[2]>16.7 for f in w),'A_gt50':sum(f[2]>50 for f in w),'A_gt100':sum(f[2]>100 for f in w),'A_max':round(max(f[2] for f in w),1),
       'A_sum':round(sum(f[2] for f in w)),
       'A_layout_gt50':[round(f[2]) for f in sub('LAYOUT (root)') if f[2]>50],'A_build_gt20':[round(f[2]) for f in sub('BUILD') if f[2]>20],
       'A_lt50':sum(1 for l in raw['lt'] if t0<=l[0]<=t0+3000),
       'idle_s':round((i1-i0)/1000,2),'idle_frames':len(idle),'idle_fps':round(len(idle)/((i1-i0)/1000),1),'idle_frame_ms_sum':round(sum(f[2] for f in idle),1),'idle_ms_per_s':round(sum(f[2] for f in idle)/((i1-i0)/1000),1),'idle_max':round(max([f[2] for f in idle]+[0]),1),'idle_lt':len(il)}
    return r
rows={}
for c in ['motion','reduce']:
    for p in sorted(glob.glob(f'{D}/{c}?_raw.json')): rows[p.split('/')[-1][:-9]]=load(p)
for k,v in rows.items(): print(k,json.dumps(v))
print('--- median')
for c in ['motion','reduce']:
    rs=[v for k,v in rows.items() if k.startswith(c)]
    if not rs: continue
    print(c,{k:st.median([r[k] for r in rs]) for k in rs[0] if not isinstance(rs[0][k],list)})
json.dump(rows,open(f'{D}/an_a.json','w'),indent=1)
