"""M1刷新活性误报单点修复副本；禁止覆盖封存M1。"""
import hashlib,json,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OLD=ROOT/'experiments/sdram_selftest_M1'
WORK=ROOT/'experiments/sdram_selftest_M1R'
assert not WORK.exists()
for folder in ('project/src','scripts','tb'):
 shutil.copytree(OLD/folder,WORK/folder)
(WORK/'sim').mkdir();(WORK/'doc/output').mkdir(parents=True)
for name in ('run_sdram.sh','run_pages.sh','run_lint.sh'):
 shutil.copy2(OLD/'sim'/name,WORK/'sim'/name)
for name in ('ROUND2_SDC_EXPECTED.json','M1_CONSTANT_SCOPE_PROOF.json'):
 shutil.copy2(OLD/'doc/output'/name,WORK/'doc/output'/name)
path=WORK/'project/src/rtl/fdi_sdram_selftest.v'
text=path.read_text(encoding='utf-8')
text=text.replace('reads,writes,refreshes,refresh_base,flags','reads,writes,refreshes,flags')
text=text.replace('reg publish;','reg publish;reg refresh_seen_in_hold;')
text=text.replace('refreshes<=0;refresh_base<=0;flags<=0;','refreshes<=0;refresh_seen_in_hold<=0;flags<=0;')
text=text.replace('flags<=event_flags;','flags<=event_flags;\n   if(state==HOLD && refresh_ack)refresh_seen_in_hold<=1;')
text=text.replace('refresh_base<=refreshes;','refresh_seen_in_hold<=0;')
text=text.replace('if(refreshes==refresh_base)','if(!refresh_seen_in_hold && !refresh_ack)')
assert 'refresh_base' not in text
path.write_text(text,encoding='utf-8')
for name in ('project/src/rtl/fdi_sdram_selftest_top.v','tb/pages/tb_m1_pages.sv'):
 p=WORK/name;p.write_text(p.read_text(encoding='utf-8').replace('5466','5467'),encoding='utf-8')
rows=[]
for p in (WORK/'project/src').rglob('*'):
 if p.is_file() and p.name not in ('fdi_sdram_selftest.v','fdi_sdram_selftest_top.v'):
  s=OLD/'project/src'/p.relative_to(WORK/'project/src')
  digest=hashlib.sha256(s.read_bytes()).hexdigest();assert hashlib.sha256(p.read_bytes()).hexdigest()==digest
  rows.append(dict(source=s.as_posix(),path=p.relative_to(WORK).as_posix(),sha256=digest))
(WORK/'doc/output/REFERENCE_ASSETS.json').write_text(json.dumps(dict(copied=rows,diagnostic_only=True,driver_changed=False),indent=2)+'\n')
print(WORK)
