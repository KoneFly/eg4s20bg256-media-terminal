"""F8复位加固：控制域只由KEY1同步释放并经全局网分发；PLL失锁/控制复位事件计数。"""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
OLD = ROOT / 'experiments/full_observe_F7'
WORK = ROOT / 'experiments/full_harden_F8'
assert not WORK.exists(), '拒绝覆盖已有实验'
for folder in ('project/src', 'project/assets', 'scripts', 'tb/integration_lint', 'sim/integration_lint'):
    shutil.copytree(OLD / folder, WORK / folder)
(WORK / 'doc/output').mkdir(parents=True)
shutil.copy2(OLD / 'doc/output/ROUND2_SDC_EXPECTED.json', WORK / 'doc/output/ROUND2_SDC_EXPECTED.json')
shutil.copy2(OLD / 'sim/run_round2_lint.sh', WORK / 'sim/run_round2_lint.sh')


def patch(path, pairs):
    text = path.read_text(encoding='utf-8')
    for before, after in pairs:
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    path.write_text(text, encoding='utf-8')


patch(WORK / 'project/src/rtl/v9_m6_hdmi.v', [
    ('    output wire [36:0] label_req_probe,',
     '    output wire [36:0] label_req_probe,\n    output wire video_pll_locked,'),
    ('''    // 单点实验：加载器单独从BASE50同步释放复位，四拍后启动。
    // 与扫描/W2/S2的两拍复位链区分，避免合并成共用释放节点。
    reg [3:0] loader_release;
    always @(posedge ctrl_clk or posedge rst)
        if(rst)loader_release<=4'b0000;else loader_release<={loader_release[2:0],1'b1};
    wire loader_rst_n=loader_release[3];''',
     '''    // 加载器在控制域释放后再延四拍；末级经全局网分发，避免高扇出复制成多份独立释放节点。
    // 不接PLL锁定，PLL锁定毛刺不得部分复位加载器/SDRAM引擎。
    reg [3:0] loader_release;
    always @(posedge ctrl_clk or negedge ctrl_rst_n)
        if(!ctrl_rst_n)loader_release<=4'b0000;else loader_release<={loader_release[2:0],1'b1};
    wire loader_rst_n;
    EG_LOGIC_BUFG u_loader_rst_buf(.i(loader_release[3]),.o(loader_rst_n));'''),
    ('    assign label_req_probe={probe_req_count,probe_req_addr};',
     '    assign label_req_probe={probe_req_count,probe_req_addr};\n    assign video_pll_locked=pll_locked;'),
])

patch(WORK / 'project/src/rtl/v9_udp_m6_master_top.v', [
    ('    wire ctrl_arst=reset;',
     '    // 控制域时钟为BASE50，不依赖PLL；只由KEY1复位，PLL锁定毛刺不进入控制域。\n    wire ctrl_arst=~key1;'),
    ('    wire ctrl_rst_n=!ctrl_reset_sync[1];',
     '    // 末级经全局网分发，避免高扇出复制成多份独立释放节点。\n    wire ctrl_rst_n;\n'
     '    EG_LOGIC_BUFG u_ctrl_rst_buf(.i(!ctrl_reset_sync[1]),.o(ctrl_rst_n));'),
    ('    wire [36:0] label_req_probe;',
     '''    wire [36:0] label_req_probe;
    wire video_pll_locked;
    // 只读事件计数：异步置位捕获窄脉冲，BASE50两级同步后计上升沿；仅KEY1清零。
    // bit0网络PLL失锁、bit1视频PLL失锁、bit2控制域复位(KEY1释放后应恒为0)。
    wire [2:0] event_src={!ctrl_rst_n,!video_pll_locked,reset_reg};
    reg [2:0] event_hit,event_meta,event_sync,event_last;
    reg [7:0] net_lock_events,video_lock_events;
    reg [15:0] ctrl_reset_events;
    genvar event_i;
    generate for(event_i=0;event_i<3;event_i=event_i+1)begin:g_event_hit
        always @(posedge clk_50 or posedge event_src[event_i])
            if(event_src[event_i])event_hit[event_i]<=1'b1;else event_hit[event_i]<=1'b0;
    end endgenerate
    always @(posedge clk_50 or negedge key1)
        if(!key1)begin
            event_meta<=3'b111;event_sync<=3'b111;event_last<=3'b111;
            net_lock_events<=0;video_lock_events<=0;ctrl_reset_events<=0;
        end else begin
            event_meta<=event_hit;event_sync<=event_meta;event_last<=event_sync;
            if(event_sync[0]&&!event_last[0]&&net_lock_events!=8'hff)net_lock_events<=net_lock_events+1'b1;
            if(event_sync[1]&&!event_last[1]&&video_lock_events!=8'hff)video_lock_events<=video_lock_events+1'b1;
            if(event_sync[2]&&!event_last[2]&&ctrl_reset_events!=16'hffff)ctrl_reset_events<=ctrl_reset_events+1'b1;
        end'''),
    ('.label_req_probe(label_req_probe),', '.label_req_probe(label_req_probe),.video_pll_locked(video_pll_locked),'),
    ("0:label_debug_value=16'd5476;", "0:label_debug_value=16'd5477;"),
    ("2:label_debug_value={11'd0,label_req_probe[20:16]};", "2:label_debug_value={8'd0,label_fault_code};"),
    ("3:label_debug_value=label_req_probe[15:0];", "3:label_debug_value={net_lock_events,video_lock_events};"),
    ("4:label_debug_value=label_req_probe[36:21];", "4:label_debug_value=ctrl_reset_events;"),
    ("6:label_debug_value={8'd0,label_fault_code};", "6:label_debug_value={label_req_probe[31:21],label_req_probe[20:16]};"),
    ("default:label_debug_value=16'hff00;", "default:label_debug_value=label_req_probe[15:0];"),
])

allowed = {'rtl/v9_udp_m6_master_top.v', 'rtl/v9_m6_hdmi.v'}
for original in (OLD / 'project/src').rglob('*'):
    if original.is_file() and original.relative_to(OLD / 'project/src').as_posix() not in allowed:
        assert original.read_bytes() == (WORK / 'project/src' / original.relative_to(OLD / 'project/src')).read_bytes()
guard = dict(source_files=[dict(path=p.relative_to(WORK / 'project/src').as_posix(),
                              after_sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                          for p in (WORK / 'project/src').rglob('*') if p.is_file()])
(WORK / 'doc/output/SOURCE_GUARD.json').write_text(json.dumps(guard, indent=2) + '\n', encoding='utf-8')
prepare = WORK / 'scripts/prepare_round2.cjs'
prepare.write_text(prepare.read_text(encoding='utf-8').replace("'FULL_OBSERVE_F7'", "'FULL_HARDEN_F8'"), encoding='utf-8')
sources = WORK / 'sim/integration_lint/sources.f'
text = sources.read_text(encoding='utf-8').replace('/experiments/full_observe_F7/', '/experiments/full_harden_F8/')
assert '/experiments/full_observe_F7/' not in text
sources.write_text(text, encoding='utf-8', newline='\n')
run_text = (OLD / 'sim/run_f7_observe.sh').read_text(encoding='utf-8').replace('f7_observe', 'f8_harden')
(WORK / 'sim/run_f8_harden.sh').write_text(run_text, encoding='utf-8', newline='\n')
text = (OLD / 'tb/tb_f7_observe.sv').read_text(encoding='utf-8').replace('tb_f7_observe', 'tb_f8_harden').replace('F7_', 'F8_')
for before, after in [
    # 控制域两拍同步释放后，加载器再延四拍：共六拍。
    ('   repeat(3)begin @(posedge clk_50);@(negedge clk_50);\n    assert(!dut.u_display.loader_rst_n)else $fatal(1,"加载器复位过早释放");end\n',
     '   repeat(5)begin @(posedge clk_50);@(negedge clk_50);\n    assert(!dut.u_display.loader_rst_n)else $fatal(1,"加载器复位过早释放");end\n'),
    ('"加载器复位未在四拍后释放"', '"加载器复位未在六拍后释放"'),
    ('   assert(dut.label_req_probe==0)else $fatal(1,"无显示读请求时探针非零");\n',
     '   assert(dut.label_req_probe==0)else $fatal(1,"无显示读请求时探针非零");\n'
     '   assert(dut.net_lock_events==0 && dut.video_lock_events==0 && dut.ctrl_reset_events==0)\n'
     '    else $fatal(1,"无失锁时事件计数非零");\n'),
]:
    assert text.count(before) == 1, before
    text = text.replace(before, after)
(WORK / 'tb/tb_f8_harden.sv').write_text(text, encoding='utf-8', newline='\n')
print(WORK)
