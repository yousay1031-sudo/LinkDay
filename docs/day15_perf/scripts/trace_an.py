import json,sys,glob,os
from collections import defaultdict
def load(p):
    t=json.load(open(p)); return t['traceEvents'] if isinstance(t,dict) else t
out={}
for p in sorted(glob.glob('bench/traces/*.json')):
    ev=load(p); name=os.path.basename(p)[:-5]
    # renderer main thread: thread_name CrRendererMain
    tn={}
    for e in ev:
        if e.get('ph')=='M' and e.get('name')=='thread_name': tn[(e['pid'],e['tid'])]=e['args']['name']
    main=[k for k,v in tn.items() if v=='CrRendererMain']
    gpu=[k for k,v in tn.items() if v in('CrGpuMain',)]
    comp=[k for k,v in tn.items() if v=='Compositor']
    def tasks(keys,nm='RunTask'):
        r=[]
        for e in ev:
            if e.get('ph')=='X' and (e['pid'],e['tid']) in keys and e.get('name')==nm and e.get('dur',0)>0: r.append((e['ts']/1000,e['dur']/1000))
        return sorted(r)
    mt=tasks(main); gt=tasks(gpu)
    # 主要: main thread RunTask > 50ms
    big=[(round(t),round(d)) for t,d in mt if d>50]
    # GPUTask
    gpu_tasks=[(e['ts']/1000,e['dur']/1000) for e in ev if e.get('ph')=='X' and e.get('name')=='GPUTask' and e.get('dur',0)>0]
    gsum=sum(d for t,d in gpu_tasks); gbig=[round(d) for t,d in gpu_tasks if d>16]
    # Swap / Presentation
    # FunctionCall / v8 の長大タスク
    out[name]={'main_tasks':len(mt),'main_tasks_gt50':big,'main_busy_ms':round(sum(d for t,d in mt)),'gpu_task_n':len(gpu_tasks),'gpu_busy_ms':round(gsum),'gpu_tasks_gt16':gbig[:10],'span_ms':round((max(e['ts'] for e in ev if 'ts' in e)-min(e['ts'] for e in ev if e.get('ts',0)>0))/1000)}
    print(name,out[name])
json.dump(out,open('trace_analysis.json','w'),indent=1)
