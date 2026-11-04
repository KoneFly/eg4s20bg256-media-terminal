"""F6只读探针：复位释放链、启动计数与独立BASE50心跳。"""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
OLD = ROOT / 'experiments/full_start_F5'
WORK = ROOT / 'experiments/full_observe_F6'
assert not WORK.exists(), '拒绝覆盖已有实验'
for folder in ('project/src', 'project/assets', 'scripts', 'tb/integration_lint', 'sim/integration_lint'):
    shutil.copytree(OLD / folder, WORK / folder)
(WORK / 'doc/output').mkdir(parents=True)
shutil.copy2(OLD / 'doc/output/ROUND2_SDC_EXPECTED.json', WORK / 'doc/output/ROUND2_SDC_EXPECTED.json')
shutil.copy2(OLD / 'sim/run_round2_lint.sh', WORK / 'sim/run_round2_lint.sh')

display = WORK / 'project/src/rtl/v9_m6_hdmi.v'
text = display.read_text(encoding='utf-8')
anchor = '    output wire [44:0] label_debug_progress,'
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '\n    output wire [15:0] label_start_status,')
anchor = '    wire loader_rst_n=loader_release[3];'
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '''
    // 只读：SDRAM完成/内部态、加载器内部态、全局及局部复位释放。
    assign label_start_status={label_debug_progress[44],label_debug_snapshot[86:82],
                               label_state,ctrl_rst_n,rst,loader_release};''')
display.write_text(text, encoding='utf-8')

top = WORK / 'project/src/rtl/v9_udp_m6_master_top.v'
text = top.read_text(encoding='utf-8')
anchor = '    wire [44:0] label_debug_progress;'
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '''
    wire [15:0] label_start_status;
    // 独立只读BASE50心跳；仅由按键复位，不参与任何功能控制。
    reg [31:0] debug_base_cycles;
    always @(posedge clk_50 or negedge key1)
        if(!key1)debug_base_cycles<=0;else debug_base_cycles<=debug_base_cycles+1'b1;''')
anchor = '.label_debug_snapshot(label_debug_snapshot),.label_debug_progress(label_debug_progress),'
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '\n        .label_start_status(label_start_status),')
replacements = {
    "0:label_debug_value=16'd5474;": "0:label_debug_value=16'd5475;",
    "2:label_debug_value={8'd0,label_fault_code};": "2:label_debug_value={3'd0,label_debug_progress[28:16]};",
    "3:label_debug_value={3'd0,label_debug_progress[28:16]};": "3:label_debug_value=label_debug_progress[15:0];",
    "4:label_debug_value=label_debug_snapshot[15:0];": "4:label_debug_value={1'b0,label_debug_progress[43:29]};",
    "5:label_debug_value=label_debug_snapshot[63:48];": "5:label_debug_value=label_start_status;",
    "6:label_debug_value=label_debug_snapshot[111:96];": "6:label_debug_value=debug_base_cycles[31:16];",
}
for before, after in replacements.items():
    assert text.count(before) == 1, before
    text = text.replace(before, after)
top.write_text(text, encoding='utf-8')
allowed = {'rtl/v9_udp_m6_master_top.v', 'rtl/v9_m6_hdmi.v'}
for original in (OLD / 'project/src').rglob('*'):
    if original.is_file() and original.relative_to(OLD / 'project/src').as_posix() not in allowed:
        assert original.read_bytes() == (WORK / 'project/src' / original.relative_to(OLD / 'project/src')).read_bytes()
guard = dict(source_files=[dict(path=p.relative_to(WORK / 'project/src').as_posix(),
                              after_sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                          for p in (WORK / 'project/src').rglob('*') if p.is_file()])
(WORK / 'doc/output/SOURCE_GUARD.json').write_text(json.dumps(guard, indent=2) + '\n', encoding='utf-8')
prepare = WORK / 'scripts/prepare_round2.cjs'
prepare.write_text(prepare.read_text(encoding='utf-8').replace("'FULL_START_F5'", "'FULL_OBSERVE_F6'"), encoding='utf-8')
sources = WORK / 'sim/integration_lint/sources.f'
text = sources.read_text(encoding='utf-8').replace('/experiments/full_start_F5/', '/experiments/full_observe_F6/')
assert '/experiments/full_start_F5/' not in text
sources.write_text(text, encoding='utf-8', newline='\n')
run_text = (OLD / 'sim/run_f5_start.sh').read_text(encoding='utf-8').replace('f5_start', 'f6_observe')
(WORK / 'sim/run_f6_observe.sh').write_text(run_text, encoding='utf-8', newline='\n')
text = (OLD / 'tb/tb_f5_start.sv').read_text(encoding='utf-8').replace('tb_f5_start', 'tb_f6_observe').replace('F5_', 'F6_')
anchor = '   $display("F6_RESET_PASS watchdog=%0d CMD0_timeout_seen=1 reader_R1=ff",dut.label_debug_progress[28:0]);'
assert text.count(anchor) == 1
text = text.replace(anchor, '''   assert(dut.label_start_status[3:0]==15 && !dut.label_start_status[4]
          && dut.label_start_status[5] && dut.label_start_status[9:6]==1
          && dut.label_start_status[15]) else $fatal(1,"启动状态只读接线错误");
   assert(dut.debug_base_cycles>624000)else $fatal(1,"独立BASE50心跳未推进");
''' + anchor)
(WORK / 'tb/tb_f6_observe.sv').write_text(text, encoding='utf-8', newline='\n')
print(WORK)
