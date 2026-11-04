"""F1最小恢复：L1加载时钟接回完整显示，保留CRC及首错页。"""
from pathlib import Path
import hashlib,json,shutil

ROOT=Path(__file__).resolve().parents[1]
A4=ROOT/'experiments/board_0x46_A4_work'
L1=ROOT/'experiments/label_debug_L1'
WORK=ROOT/'experiments/full_debug_F1'
assert not WORK.exists()
for folder in ('project/src','project/assets','scripts'):
 shutil.copytree(A4/folder,WORK/folder)
(WORK/'doc/output').mkdir(parents=True)
(WORK/'sim').mkdir();(WORK/'tb').mkdir()
shutil.copy2(L1/'project/src/rtl/fdi_label_store.v',WORK/'project/src/rtl/fdi_label_store.v')
p=WORK/'project/src/rtl/v9_udp_m6_master_top.v'
s=p.read_text(encoding='utf-8')
s=s[:s.index('// A4只读事件观测')]
s=s.replace('wire ctrl_clk, mem_clk;','wire ctrl_clk, mem_clk;\n    assign ctrl_clk=clk_50;')
s=s.replace('.ctrl_clk(ctrl_clk),.mem_clk(mem_clk));','.ctrl_clk(),.mem_clk(mem_clk));')
s=s.replace('wire [44:0] label_debug_progress;','wire [44:0] label_debug_progress;\n    wire [31:0] label_file_crc,label_memory_crc;')
s=s.replace('.label_debug_snapshot(label_debug_snapshot),.label_debug_progress(label_debug_progress),',
 '.label_debug_snapshot(label_debug_snapshot),.label_debug_progress(label_debug_progress),\n        .label_file_crc(label_file_crc),.label_memory_crc(label_memory_crc),')
a=s.index('    // A3只读启动进度');b=s.index('    wire [15:0] display_value',a)
s=s[:a]+'''    reg [15:0] label_debug_value;
    wire [7:0] load_flags={label_fault_code!=0,!reset,ctrl_rst_n,
      label_debug_snapshot[3:0]==4'd10,label_memory_crc==32'ha1e4d4e1,
      label_file_crc==32'h47e2a01d,label_debug_snapshot[15],label_debug_progress[44]};
    always @(*)case(sw[3:1])
      0:label_debug_value=16'd5470;
      1:label_debug_value={8'd0,load_flags};
      2:label_debug_value={8'd0,label_fault_code};
      3:label_debug_value=label_file_crc[15:0];
      4:label_debug_value=label_file_crc[31:16];
      5:label_debug_value=label_memory_crc[15:0];
      6:label_debug_value=label_memory_crc[31:16];
      default:label_debug_value=16'hff00;
    endcase
'''+s[b:]
p.write_text(s,encoding='utf-8')
p=WORK/'project/src/rtl/v9_m6_hdmi.v';s=p.read_text(encoding='utf-8')
s=s.replace('output wire [44:0] label_debug_progress,',
 'output wire [44:0] label_debug_progress,\n    output reg [31:0] label_file_crc,label_memory_crc,')
s=s.replace('wire [7:0] store_error,stream_error,scan_error;',
 'wire [7:0] store_error,stream_error,scan_error;\n    wire [3:0] label_state;wire [31:0] label_crc;')
s=s.replace('.debug_progress(label_debug_progress));',
 '.debug_progress(label_debug_progress),.debug_state_live(label_state),.debug_crc32(label_crc));\n'
 '    always @(posedge ctrl_clk or negedge ctrl_rst_n)begin\n'
 '        if(!ctrl_rst_n)begin label_file_crc<=0;label_memory_crc<=0;end\n'
 '        else begin\n'
 '            if(label_state==4)label_file_crc<=label_crc;\n'
 '            if(label_state>=5 && label_state<=10)label_memory_crc<=label_crc;\n'
 '        end\n    end')
p.write_text(s,encoding='utf-8')
p=WORK/'project/src/constraints/eth_m6_master.sdc'
s=p.read_text(encoding='utf-8').replace('u_clk/u_pll_0/pll_inst.clkc[1]','clk_50')
# 同一BASE域的store/stream错误不再跨域，scan错误仍来自PIXEL。
# 保留既有错误同步及首级D口径，后续原生工具按实际端点核验。
p.write_text(s,encoding='utf-8')
expected=json.loads((A4/'doc/output/ROUND2_SDC_EXPECTED.json').read_text())
expected['sdc_sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
(WORK/'doc/output/ROUND2_SDC_EXPECTED.json').write_text(json.dumps(expected,indent=2)+'\n')
guard=dict(source_files=[dict(path=p.relative_to(WORK/'project/src').as_posix(),
 after_sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in (WORK/'project/src').rglob('*') if p.is_file()])
(WORK/'doc/output/SOURCE_GUARD.json').write_text(json.dumps(guard,indent=2)+'\n')
p=WORK/'scripts/prepare_round2.cjs';s=p.read_text(encoding='utf-8').replace("'BOARD_0x46_A4'","'FULL_DEBUG_F1'")
p.write_text(s,encoding='utf-8')
p=WORK/'scripts/read_round2.cjs';s=p.read_text(encoding='utf-8').replace("'u_clk/u_pll_0/pll_inst.clkc[1]',",'')
p.write_text(s,encoding='utf-8')
# 复用已修正的物理引脚映射解析，不扩大CDC豁免。
p=WORK/'scripts/remap_physical_sdc.py'
s=(L1/'scripts/remap_physical_sdc.py').read_text(encoding='utf-8')
s=s.replace('td_run/check_m1_final/gate_netlist.v','td_run/check_f1/gate_netlist.v')
s=s.replace("'u_display/u_label_store/u_check_buffer/wr_clk':'u_clk/u_pll_0/pll_inst.clkc[1]'",
 "'u_display/u_label_store/u_check_buffer/wr_clk':'clk_50'")
a=s.index("record['untimed_hardmacro_endpoints']");b=s.index("(run/'PHYSICAL_SDC_EXPECTED.json')",a)
s=s[:a]+s[b:]
p.write_text(s,encoding='utf-8')
shutil.copytree(A4/'tb/controlled_loader',WORK/'tb/controlled_loader')
p=WORK/'tb/controlled_loader/tb_controlled_loader.sv'
s=p.read_text(encoding='utf-8').replace('wire [44:0] debug_progress;',
 'wire [44:0] debug_progress;wire [3:0] debug_state_live;wire [31:0] debug_crc32;')
p.write_text(s,encoding='utf-8')
# 直接复用L1已测完整受控素材，不生成新卡或更改素材布局。
for name in ('controlled_image.memh','label_words.memh'):
 shutil.copy2(L1/'tb'/name,WORK/'tb/controlled_loader'/name)
shutil.copytree(ROOT/'sim/integration_lint',WORK/'sim/integration_lint',ignore=shutil.ignore_patterns('*.log','*.json'))
p=WORK/'sim/integration_lint/sources.f'
s=p.read_text(encoding='utf-8').replace(ROOT.as_posix(),WORK.as_posix())
# sources.f使用WSL路径；替换同一根目录的WSL表示。
old_wsl='/mnt/d/'+ROOT.as_posix()[3:]
new_wsl='/mnt/d/'+WORK.as_posix()[3:]
s=s.replace(old_wsl,new_wsl)
p.write_text(s,encoding='utf-8')
shutil.copy2(ROOT/'sim/run_round2_lint.sh',WORK/'sim/run_round2_lint.sh')
print(WORK)
