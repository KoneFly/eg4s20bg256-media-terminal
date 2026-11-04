"""F7只读探针：冻结加载器报错前最后一次显示读请求地址与已接受请求数。"""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
OLD = ROOT / 'experiments/full_observe_F6'
WORK = ROOT / 'experiments/full_observe_F7'
assert not WORK.exists(), '拒绝覆盖已有实验'
for folder in ('project/src', 'project/assets', 'scripts', 'tb/integration_lint', 'sim/integration_lint'):
    shutil.copytree(OLD / folder, WORK / folder)
(WORK / 'doc/output').mkdir(parents=True)
shutil.copy2(OLD / 'doc/output/ROUND2_SDC_EXPECTED.json', WORK / 'doc/output/ROUND2_SDC_EXPECTED.json')
shutil.copy2(OLD / 'sim/run_round2_lint.sh', WORK / 'sim/run_round2_lint.sh')

display = WORK / 'project/src/rtl/v9_m6_hdmi.v'
text = display.read_text(encoding='utf-8')
anchor = '    output wire [15:0] label_start_status,'
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '\n    output wire [36:0] label_req_probe,')
anchor = '''                               label_state,ctrl_rst_n,rst,loader_release};'''
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '''
    // 只读：加载器报错(0x45越界等)的同一沿仍锁存当拍请求地址，此后冻结，KEY1复位清除。
    reg [20:0] probe_req_addr;
    reg [15:0] probe_req_count;
    always @(posedge ctrl_clk or negedge ctrl_rst_n)
        if(!ctrl_rst_n)begin probe_req_addr<=0;probe_req_count<=0;end
        else if(store_error==0 && rd_req_valid)begin
            probe_req_addr<=rd_req_addr;
            if(rd_req_ready)probe_req_count<=probe_req_count+1'b1;
        end
    assign label_req_probe={probe_req_count,probe_req_addr};''')
display.write_text(text, encoding='utf-8')

top = WORK / 'project/src/rtl/v9_udp_m6_master_top.v'
text = top.read_text(encoding='utf-8')
heartbeat = '''
    // 独立只读BASE50心跳；仅由按键复位，不参与任何功能控制。
    reg [31:0] debug_base_cycles;
    always @(posedge clk_50 or negedge key1)
        if(!key1)debug_base_cycles<=0;else debug_base_cycles<=debug_base_cycles+1'b1;'''
assert text.count(heartbeat) == 1
text = text.replace(heartbeat, '\n    wire [36:0] label_req_probe;')
anchor = '        .label_start_status(label_start_status),'
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '.label_req_probe(label_req_probe),')
replacements = {
    "0:label_debug_value=16'd5475;": "0:label_debug_value=16'd5476;",
    "2:label_debug_value={3'd0,label_debug_progress[28:16]};": "2:label_debug_value={11'd0,label_req_probe[20:16]};",
    "3:label_debug_value=label_debug_progress[15:0];": "3:label_debug_value=label_req_probe[15:0];",
    "4:label_debug_value={1'b0,label_debug_progress[43:29]};": "4:label_debug_value=label_req_probe[36:21];",
    "6:label_debug_value=debug_base_cycles[31:16];": "6:label_debug_value={8'd0,label_fault_code};",
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
prepare.write_text(prepare.read_text(encoding='utf-8').replace("'FULL_OBSERVE_F6'", "'FULL_OBSERVE_F7'"), encoding='utf-8')
sources = WORK / 'sim/integration_lint/sources.f'
text = sources.read_text(encoding='utf-8').replace('/experiments/full_observe_F6/', '/experiments/full_observe_F7/')
assert '/experiments/full_observe_F6/' not in text
sources.write_text(text, encoding='utf-8', newline='\n')
run_text = (OLD / 'sim/run_f6_observe.sh').read_text(encoding='utf-8').replace('f6_observe', 'f7_observe')
(WORK / 'sim/run_f7_observe.sh').write_text(run_text, encoding='utf-8', newline='\n')
text = (OLD / 'tb/tb_f6_observe.sv').read_text(encoding='utf-8').replace('tb_f6_observe', 'tb_f7_observe').replace('F6_', 'F7_')
before = '   assert(dut.debug_base_cycles>624000)else $fatal(1,"独立BASE50心跳未推进");\n'
assert text.count(before) == 1
text = text.replace(before, '   assert(dut.label_req_probe==0)else $fatal(1,"无显示读请求时探针非零");\n')
(WORK / 'tb/tb_f7_observe.sv').write_text(text, encoding='utf-8', newline='\n')
print(WORK)
