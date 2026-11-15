import json,glob,os
import numpy as np
from PIL import Image
R='/home/user/day15_verify/v4/rm_raw'
for d in sorted(glob.glob(R+'/ent_*/')):
    tag=os.path.basename(d.rstrip('/'));m=json.load(open(d+'ts.json'));ts=m['ts'];t0=m['tClick']
    fs=sorted(glob.glob(d+'f*.png'))
    ims=[np.asarray(Image.open(f).convert('L'),dtype=np.float32) for f in fs]
    print(tag,'size',ims[0].shape)
    # カード領域: 画面下 60%（y>340）、最終フレームとの差
    last=ims[-1]
    prev=None
    row=[]
    for t,i in zip(ts,ims):
        e=float(np.abs(i[340:790]-last[340:790]).mean())
        row.append((round((t-t0)*1000),round(e,1)))
    print(' ',row)
