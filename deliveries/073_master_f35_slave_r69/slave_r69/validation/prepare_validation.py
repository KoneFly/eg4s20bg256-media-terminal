"""新声路最小整数控制/原R64保护模型验证；不是整核RTL或实板验收。"""
from pathlib import Path
import hashlib,json,shutil,subprocess
import numpy as np
U=Path(__file__).resolve().parent;B=U.parents[1]/'anc_source_recheck_r64_20261101'
assert B.exists()
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
for n in ['rtl','tb','inputs','evidence']:(U/n).mkdir(exist_ok=True)
for n in ['anc_u64_divider_r61.v','anc_ratio_monitor_r61.v','anc_stability_guard_r61.v','anc_rise_compare_r62.v']:
    shutil.copyfile(B/'rtl'/n,U/'rtl'/n)
shutil.copyfile(B/'tb/r61_guard_default_tb.v',U/'tb/r61_guard_default_tb.v')
p=B/'tb/integer_reference_r06.hpp';s=p.read_text(encoding='utf-8').replace('../../measured_sweep01_20261031/','../../../measured_sweep01_20261031/')
(U/'tb/integer_reference_r06.hpp').write_text(s,encoding='utf-8',newline='\n')
p=B/'tb/headroom_models.cpp';s=p.read_text(encoding='utf-8')
s=s.replace('  save(outroot+"/case"+std::to_string(test.id)+"_e.f64",residual);save(outroot+"/case"+std::to_string(test.id)+"_y.f64",emitted);save(outroot+"/case"+std::to_string(test.id)+"_state.f64",states);','  // 截止前保留逐秒窗口/汇总，省去大体积逐样本数组导出。')
(U/'tb/headroom_models.cpp').write_text(s,encoding='utf-8',newline='\n')
for n in ['hp.f64','objhp.f64','lp900.f64','tone_250_500.f64','tone_500_750.f64']:
    shutil.copyfile(B/'inputs'/n,U/'inputs'/n)
n=(U/'inputs/tone_250_500.f64').stat().st_size//8
np.sin(2*np.pi*500*np.arange(n)/(50000000/4160)).astype('<f8').tofile(U/'inputs/tone_500_500.f64')
rows=[]
for plant in [0,1]:
    for low,high in [(500,500),(250,500),(500,750)]:rows.append(f'{len(rows)+1} {low} {high} 1000 .35 2 {plant} 0 67112 1')
(U/'inputs/quick_cases.txt').write_text('\n'.join(rows)+'\n')
files=[p for folder in ['rtl','tb','inputs'] for p in (U/folder).glob('*') if p.is_file()]
(U/'evidence/BUILD_INPUTS.json').write_text(json.dumps({str(p):sha(p) for p in files},indent=2)+'\n')
args=['verilator','--cc','--exe','--build','-j','3','-Wall','-Wno-UNUSEDSIGNAL','--top-module','r61_guard_default_tb','--Mdir','build_models','rtl/anc_u64_divider_r61.v','rtl/anc_ratio_monitor_r61.v','rtl/anc_stability_guard_r61.v','rtl/anc_rise_compare_r62.v','tb/r61_guard_default_tb.v','tb/headroom_models.cpp','-CFLAGS','-O3 -std=c++17 -fsanitize=undefined -fno-sanitize-recover=all','-LDFLAGS','-fsanitize=undefined']
with (U/'evidence/build.log').open('x') as f:r=subprocess.run(['wsl','--cd',str(U),'--',*args],stdout=f,stderr=subprocess.STDOUT)
assert r.returncode==0,(U/'evidence/build.log').read_text(errors='replace')[-4000:]
print('R69_MODEL_VALIDATION_READY_6_CASES')
