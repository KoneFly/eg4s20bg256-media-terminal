"""F2只读观测：保留F1功能和延迟设置，仅改数码管诊断页。"""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
OLD = ROOT / 'experiments/full_debug_F1'
WORK = ROOT / 'experiments/full_probe_F2'
assert not WORK.exists(), '拒绝覆盖已有实验'
for folder in ('project/src', 'project/assets', 'scripts', 'tb/integration_lint', 'sim/integration_lint'):
    shutil.copytree(OLD / folder, WORK / folder)
(WORK / 'doc/output').mkdir(parents=True)
shutil.copy2(OLD / 'doc/output/ROUND2_SDC_EXPECTED.json', WORK / 'doc/output/ROUND2_SDC_EXPECTED.json')
shutil.copy2(OLD / 'sim/run_round2_lint.sh', WORK / 'sim/run_round2_lint.sh')
p = WORK / 'project/src/rtl/v9_udp_m6_master_top.v'
s = p.read_text(encoding='utf-8')
changes = {
    "0:label_debug_value=16'd5470;": "0:label_debug_value=16'd5471;",
    '3:label_debug_value=label_file_crc[15:0];': "3:label_debug_value={3'd0,label_debug_progress[28:16]};",
    '4:label_debug_value=label_file_crc[31:16];': '4:label_debug_value=label_debug_progress[44:29];',
    '5:label_debug_value=label_memory_crc[15:0];': '5:label_debug_value=label_debug_snapshot[15:0];',
    '6:label_debug_value=label_memory_crc[31:16];': '6:label_debug_value=label_debug_snapshot[95:80];',
}
for before, after in changes.items():
    assert s.count(before) == 1, before
    s = s.replace(before, after)
p.write_text(s, encoding='utf-8')
for old_p in (OLD / 'project/src').rglob('*'):
    if old_p.is_file() and old_p.relative_to(OLD / 'project/src').as_posix() != 'rtl/v9_udp_m6_master_top.v':
        assert old_p.read_bytes() == (WORK / 'project/src' / old_p.relative_to(OLD / 'project/src')).read_bytes()
guard = dict(source_files=[dict(path=p.relative_to(WORK / 'project/src').as_posix(),
             after_sha256=hashlib.sha256(p.read_bytes()).hexdigest())
             for p in (WORK / 'project/src').rglob('*') if p.is_file()])
(WORK / 'doc/output/SOURCE_GUARD.json').write_text(json.dumps(guard, indent=2) + '\n')
p = WORK / 'scripts/prepare_round2.cjs'
s = p.read_text(encoding='utf-8').replace("'FULL_DEBUG_F1'", "'FULL_PROBE_F2'")
s = s.replace("manifest.mapping_strategy='TD_official_AreaOptimizeHigh'", "manifest.mapping_strategy='TD_default'")
area_line = next(line for line in s.splitlines() if 'commands.splice(rtlOpt,0' in line)
s = s.replace(area_line, '')
p.write_text(s, encoding='utf-8')
p = WORK / 'scripts/remap_physical_sdc.py'
p.write_text(p.read_text(encoding='utf-8').replace('td_run/check_f1/gate_netlist.v',
             'td_run/check_f2/gate_netlist.v'), encoding='utf-8')
p = WORK / 'sim/integration_lint/sources.f'
s = p.read_text(encoding='utf-8')
s = s.replace('/mnt/d/' + OLD.as_posix()[3:], '/mnt/d/' + WORK.as_posix()[3:])
p.write_text(s, encoding='utf-8')
print(WORK)
