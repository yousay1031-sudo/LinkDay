import os,json,glob
from PIL import Image, ImageChops
import numpy as np
R='/home/user/day15_verify/v4/rm_raw'
out={}
# skeleton: mean luminance of the skeleton region across screenshots; amplitude
for d in sorted(glob.glob(R+'/sk_*/')):
    tag=os.path.basename(d.rstrip('/'))
    fs=sorted(glob.glob(d+'s*.png'))
    ims=[np.asarray(Image.open(f).convert('L'),dtype=np.float32) for f in fs]
    means=[float(i.mean()) for i in ims]
    diffs=[float(np.abs(ims[i+1]-ims[i]).mean()) for i in range(len(ims)-1)]
    out[tag]={'n':len(ims),'mean_range':round(max(means)-min(means),3),'max_frame_diff':round(max(diffs),3),'mean_frame_diff':round(sum(diffs)/len(diffs),3),'means':[round(m,2) for m in means]}
# entrance: frames after click
for d in sorted(glob.glob(R+'/ent_*/')):
    tag=os.path.basename(d.rstrip('/'))
    meta=json.load(open(d+'ts.json'));ts=meta['ts']
    fs=sorted(glob.glob(d+'f*.png'))
    ims=[np.asarray(Image.open(f).convert('L').resize((195,422)),dtype=np.float32) for f in fs]
    diffs=[float(np.abs(ims[i+1]-ims[i]).mean()) for i in range(len(ims)-1)]
    ch=[i for i,x in enumerate(diffs) if x>0.15]
    # カード領域(下半分)の輝度が最終フレームに収束するまで
    last=ims[-1]; err=[float(np.abs(i-last).mean()) for i in ims]
    first_ch=ch[0] if ch else None; last_ch=ch[-1] if ch else None
    out[tag]={'frames':len(ims),'changing_frames':len(ch),'change_span_ms':round((ts[last_ch+1]-ts[first_ch])*1000) if ch else 0,'distinct_intermediate':sum(1 for e in err if 0.5<e<30),'max_err_to_final':round(max(err),2)}
json.dump(out,open('/home/user/day15_verify/v4/rm_analysis.json','w'),indent=1)
for k,v in out.items(): print(k,{a:b for a,b in v.items() if a!='means'})
