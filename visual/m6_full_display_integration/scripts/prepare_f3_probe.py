"""F3只读观测：显示现有冻结快照中的命令器和字节引擎握手。"""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
OLD = ROOT / 'experiments/full_probe_F2_logic'
WORK = ROOT / 'experiments/full_probe_F3'
assert not WORK.exists(), '拒绝覆盖已有实验'
for folder in ('project/src', 'project/assets', 'scripts'):
    shutil.copytree(OLD / folder, WORK / folder)
(WORK / 'doc/output').mkdir(parents=True)
shutil.copy2(OLD / 'doc/output/ROUND2_SDC_EXPECTED.json', WORK / 'doc/output/ROUND2_SDC_EXPECTED.json')
top = WORK / 'project/src/rtl/v9_udp_m6_master_top.v'
text = top.read_text(encoding='utf-8')
changes = {
    "0:label_debug_value=16'd5471;": "0:label_debug_value=16'd5472;",
    "3:label_debug_value={3'd0,label_debug_progress[28:16]};": '3:label_debug_value=label_debug_snapshot[63:48];',
    '4:label_debug_value=label_debug_progress[44:29];': '4:label_debug_value=label_debug_snapshot[31:16];',
    '5:label_debug_value=label_debug_snapshot[15:0];': '5:label_debug_value=label_debug_snapshot[47:32];',
    '6:label_debug_value=label_debug_snapshot[95:80];': '6:label_debug_value=label_debug_snapshot[111:96];',
}
for before, after in changes.items():
    assert text.count(before) == 1, before
    text = text.replace(before, after)
top.write_text(text, encoding='utf-8')
for original in (OLD / 'project/src').rglob('*'):
    if original.is_file() and original.relative_to(OLD / 'project/src').as_posix() != 'rtl/v9_udp_m6_master_top.v':
        assert original.read_bytes() == (WORK / 'project/src' / original.relative_to(OLD / 'project/src')).read_bytes()
guard = dict(source_files=[dict(path=p.relative_to(WORK / 'project/src').as_posix(),
                              after_sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                          for p in (WORK / 'project/src').rglob('*') if p.is_file()])
(WORK / 'doc/output/SOURCE_GUARD.json').write_text(json.dumps(guard, indent=2) + '\n')
prepare = WORK / 'scripts/prepare_round2.cjs'
prepare.write_text(prepare.read_text(encoding='utf-8').replace("'FULL_PROBE_F2'", "'FULL_PROBE_F3'"), encoding='utf-8')
lint_source = ROOT / 'experiments/full_probe_F2'
for folder in ('tb/integration_lint', 'sim/integration_lint'):
    shutil.copytree(lint_source / folder, WORK / folder)
shutil.copy2(lint_source / 'sim/run_round2_lint.sh', WORK / 'sim/run_round2_lint.sh')
sources = WORK / 'sim/integration_lint/sources.f'
sources.write_text(sources.read_text().replace('/experiments/full_probe_F2/', '/experiments/full_probe_F3/'))
print(WORK)
