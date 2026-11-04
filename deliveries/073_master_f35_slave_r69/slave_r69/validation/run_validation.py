from pathlib import Path
import hashlib,json,re,shutil,subprocess
import numpy as np
U=Path(__file__).resolve().parent;M=U.parent/'model'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
inputs={};coefficient_text=(M/'anc_core_constants_r61.vh').read_text(encoding='utf-8')
for ch,label in [(0,'secondary'),(1,'feedback')]:
    h=np.fromfile(M/'effective'/f'full_{ch}.f64',dtype='<f8')
    expected=(np.sign(h)*np.floor(abs(h)*32768+.5)).astype(np.int64)
    part=coefficient_text[coefficient_text.index('function signed [17:0] '+label+'_coefficient'):];part=part[:part.index('endfunction')]
    got=np.zeros(256,dtype=np.int64)
    for idx,value in re.findall(r"8'd(\d+):"+label+r"_coefficient=18'sh([0-9a-fA-F]+)",part):
        value=int(value,16);got[int(idx)]=value-(1<<18) if value&(1<<17) else value
    assert len(expected)==152 and np.array_equal(got[:152],expected) and not got[152:].any(),label
    assert expected.min()>=-32768 and expected.max()<=32767
filters=[]
for name in ['hp.f64','objhp.f64','lp900.f64']:
    for row in np.fromfile(U/'inputs'/name,dtype='<f8').reshape(-1,6):
        filters.append([int(np.sign(row[i])*np.floor(abs(row[i])*65536+.5)) for i in [0,1,2,4,5]])
for idx,encoded in re.findall(r"3'd(\d+):sos_coefficients=\{([^}]+)\}",coefficient_text):
    decoded=[]
    for value in re.findall(r"18'sh([0-9a-fA-F]+)",encoded):
        value=int(value,16);decoded.append(value-(1<<18) if value&(1<<17) else value)
    assert decoded==filters[int(idx)],('SOS model vs RTL',idx)
inputs[str(M/'anc_core_constants_r61.vh')]=sha(M/'anc_core_constants_r61.vh')
for n in ['full_0.f64','full_1.f64','half_0.f64','half_1.f64']:
    p=M/'effective'/n;h=np.fromfile(p,dtype='<f8');assert len(h)==152 and h[0]==0 and np.isfinite(h).all(),p
    dest=U/'inputs'/n
    if dest.exists(): assert sha(dest)==sha(p),('INPUT_MISMATCH',n)
    else: shutil.copyfile(p,dest)
    inputs[str(p)]=sha(p)
(U/'evidence/MODEL_INPUTS.json').write_text(json.dumps(inputs,indent=2)+'\n')
with (U/'evidence/models.log').open('x') as f:r=subprocess.run(['wsl','--cd',str(U),'--','./build_models/Vr61_guard_default_tb','evidence','inputs/quick_cases.txt'],stdout=f,stderr=subprocess.STDOUT)
assert r.returncode==0,(U/'evidence/models.log').read_text(errors='replace')[-4000:]
rows=[json.loads(x) for x in (U/'evidence/headroom_models.jsonl').read_text().splitlines()]
assert len(rows)==6
numeric=all(row['raw_fault_samples']==0 and row['filter_saturations']==0 and row['history_saturations']==0 and row['max_output_PCM']<=12288 for row in rows)
complete=all(row['final_state']==4 and row['first_RUN_s']>=0 for row in rows)
v={'status':'PASS_NUMERIC_AND_RUN_MODEL_CASES' if numeric and complete else 'REVIEW_MODEL_CASE_RESULTS','numerical_gate_pass':numeric,'all_cases_end_RUN':complete,'model_input_sha256':inputs,'cases':rows,'evidence_level':'Integer controller plus original R64 RTL supervisor and measured normal/half floating plant; primary gain0.35/delay2 assumed. Not full current RTL, not physical dB acceptance.','source_peak_PCM':1000,'output_bound':12288,'mu_Q24':67112,'old_trace_identity_required':False}
(U/'evidence/RESULT.json').write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(json.dumps(v,ensure_ascii=False,indent=2))
