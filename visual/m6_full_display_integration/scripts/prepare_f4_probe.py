"""F4单点实验：标签加载器独立复位释放，保留加载进度与SPI状态观测。"""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
OLD = ROOT / 'experiments/full_probe_F3'
WORK = ROOT / 'experiments/full_reset_F4'
assert not WORK.exists(), '拒绝覆盖已有实验'
for folder in ('project/src', 'project/assets', 'scripts', 'tb/integration_lint', 'sim/integration_lint'):
    shutil.copytree(OLD / folder, WORK / folder)
(WORK / 'doc/output').mkdir(parents=True)
shutil.copy2(OLD / 'doc/output/ROUND2_SDC_EXPECTED.json', WORK / 'doc/output/ROUND2_SDC_EXPECTED.json')
shutil.copy2(OLD / 'sim/run_round2_lint.sh', WORK / 'sim/run_round2_lint.sh')
top = WORK / 'project/src/rtl/v9_udp_m6_master_top.v'
text = top.read_text(encoding='utf-8')
for before, after in {
    "0:label_debug_value=16'd5472;": "0:label_debug_value=16'd5473;",
    '3:label_debug_value=label_debug_snapshot[63:48];': "3:label_debug_value={3'd0,label_debug_progress[28:16]};",
    '4:label_debug_value=label_debug_snapshot[31:16];': '4:label_debug_value=label_debug_snapshot[15:0];',
    '5:label_debug_value=label_debug_snapshot[47:32];': '5:label_debug_value=label_debug_snapshot[63:48];',
}.items():
    assert text.count(before) == 1, before
    text = text.replace(before, after)
top.write_text(text, encoding='utf-8')
hdmi = WORK / 'project/src/rtl/v9_m6_hdmi.v'
text = hdmi.read_text(encoding='utf-8')
before = '    fdi_label_store u_label_store(.clk(ctrl_clk),.mem_clk(mem_clk),.rst_n(ctrl_rst_n),'
after = '''    // 单点实验：加载器单独从BASE50同步释放复位，四拍后启动。
    // 与扫描/W2/S2的两拍复位链区分，避免合并成共用释放节点。
    reg [3:0] loader_release;
    always @(posedge ctrl_clk or posedge rst)
        if(rst)loader_release<=4'b0000;else loader_release<={loader_release[2:0],1'b1};
    wire loader_rst_n=loader_release[3];
    fdi_label_store u_label_store(.clk(ctrl_clk),.mem_clk(mem_clk),.rst_n(loader_rst_n),'''
assert text.count(before) == 1
hdmi.write_text(text.replace(before, after), encoding='utf-8')
allowed = {'rtl/v9_udp_m6_master_top.v', 'rtl/v9_m6_hdmi.v'}
for original in (OLD / 'project/src').rglob('*'):
    if original.is_file() and original.relative_to(OLD / 'project/src').as_posix() not in allowed:
        assert original.read_bytes() == (WORK / 'project/src' / original.relative_to(OLD / 'project/src')).read_bytes()
guard = dict(source_files=[dict(path=p.relative_to(WORK / 'project/src').as_posix(),
                              after_sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                          for p in (WORK / 'project/src').rglob('*') if p.is_file()])
(WORK / 'doc/output/SOURCE_GUARD.json').write_text(json.dumps(guard, indent=2) + '\n')
prepare = WORK / 'scripts/prepare_round2.cjs'
prepare.write_text(prepare.read_text(encoding='utf-8').replace("'FULL_PROBE_F3'", "'FULL_RESET_F4'"), encoding='utf-8')
sources = WORK / 'sim/integration_lint/sources.f'
source_text = sources.read_text().replace('/experiments/full_probe_F2/', '/experiments/full_reset_F4/').replace('/experiments/full_probe_F3/', '/experiments/full_reset_F4/')
assert '/experiments/full_probe_F2/' not in source_text and '/experiments/full_probe_F3/' not in source_text
sources.write_text(source_text)
print(WORK)
