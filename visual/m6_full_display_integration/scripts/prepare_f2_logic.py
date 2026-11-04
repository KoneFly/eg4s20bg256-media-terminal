"""隔离映射策略实验，功能源逐文件保持F2一致。"""
from pathlib import Path
import shutil
ROOT=Path(__file__).resolve().parents[1]
OLD=ROOT/'experiments/full_probe_F2'
WORK=ROOT/'experiments/full_probe_F2_logic'
assert not WORK.exists()
for folder in ('project/src','project/assets','scripts'):
    shutil.copytree(OLD/folder,WORK/folder)
(WORK/'doc/output').mkdir(parents=True)
for name in ('SOURCE_GUARD.json','ROUND2_SDC_EXPECTED.json'):
    shutil.copy2(OLD/'doc/output'/name,WORK/'doc/output'/name)
for p in (OLD/'project/src').rglob('*'):
    if p.is_file():assert p.read_bytes()==(WORK/'project/src'/p.relative_to(OLD/'project/src')).read_bytes()
print(WORK)
