"""创建最小L1调试副本：整图加载及原双CRC，保留彩条与S1观测。"""
from pathlib import Path
import json
import shutil
import hashlib

ROOT=Path(__file__).resolve().parents[1]
OLD=ROOT/'experiments/tf_selftest_TF1'
A4=ROOT/'experiments/board_0x46_A4_work'
WORK=ROOT/'experiments/label_debug_L1'
assert not WORK.exists()
for p in (OLD/'project/src').rglob('*'):
 if p.is_file() and p.name not in ('fdi_sdram_selftest.v','fdi_tf_selftest.v'):
  target=WORK/'project/src'/p.relative_to(OLD/'project/src')
  target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
shutil.copytree(OLD/'scripts',WORK/'scripts')
(WORK/'doc/output').mkdir(parents=True)
(WORK/'tb').mkdir();(WORK/'sim').mkdir()
for name in ('fdi_state_lane.v','fdi_label_store.v'):
 shutil.copy2(A4/'project/src/rtl'/name,WORK/'project/src/rtl'/name)
p=WORK/'project/src/rtl/fdi_label_store.v'
s=p.read_text(encoding='utf-8')
s=s.replace('output wire rd_done,output reg [111:0]',
 'output wire rd_done,output wire [3:0] debug_state_live,output wire [31:0] debug_crc32,output reg [111:0]')
a=s.index(' // A2单点实验：');b=s.index(' reg init_start',a)
s=s[:a]+' // 沿用TF1真板通过的直连MISO；不改变原SPI引擎。\n'+s[b:]
s=s.replace('miso_hold[2]','sd_miso')
s=s.replace(' reg [31:0] crc_work,crc_data;',
 ' reg [31:0] crc_work,crc_data;\n assign debug_state_live=state;\n assign debug_crc32=~crc_work;')
p.write_text(s,encoding='utf-8')
p=WORK/'project/src/rtl/fdi_sdram_selftest_top.v'
s=p.read_text(encoding='utf-8')
s=s[:s.index(' // S1自检继续运行')]+'''
 wire s1_healthy=captured_valid && !captured_mismatch && captured_flags==4'hf &&
                 captured_dut==29'd499999 && captured_reference==29'd499999;
 // SDRAM时钟锁定后在BASE域同步释放加载器复位；SPI及加载控制使用已验BASE域。
 reg [1:0] store_reset_sync;
 always @(posedge clk_50 or posedge reset)
  if(reset)store_reset_sync<=2'b11;else store_reset_sync<={store_reset_sync[0],1'b0};
 wire store_rst_n=!store_reset_sync[1];
 wire label_ready;wire [7:0] store_error;wire [111:0] debug_snapshot;
 wire [44:0] debug_progress;wire [3:0] store_state;wire [31:0] store_crc;
 fdi_label_store u_store(.clk(clk_50),.mem_clk(mem_clk),.rst_n(store_rst_n),
  .sd_miso(sd_miso),.sd_dclk(sd_dclk),.sd_mosi(sd_mosi),.sd_ncs(sd_ncs),
  .label_ready(label_ready),.error_code(store_error),.rd_req_valid(1'b0),.rd_req_addr(21'h40000),
  .rd_req_ready(),.rd_beat_valid(),.rd_beat_data(),.rd_beat_addr(),.rd_done(),
  .debug_snapshot(debug_snapshot),.debug_progress(debug_progress),
  .debug_state_live(store_state),.debug_crc32(store_crc));
 reg [31:0] file_crc,memory_crc;
 always @(posedge clk_50 or negedge key1)begin
  if(!key1)begin file_crc<=0;memory_crc<=0;end
  else begin
   if(store_state==4'd4)file_crc<=store_crc;
   if(store_state>=4'd5 && store_state<=4'd10)memory_crc<=store_crc;
  end
 end
 wire [19:0] byte_count={debug_snapshot[51:48],debug_snapshot[47:32]};
 wire [7:0] flags={store_error!=0,label_ready && store_error==0,s1_healthy,
  byte_count==20'd921654,label_ready,file_crc==32'h47e2a01d,debug_snapshot[15],debug_progress[44]};
 reg [15:0] value;
 always @(*)case(sw[3:1])
  0:value=16'd5469;
  1:value=sw[0]?{8'd0,flags}:debug_snapshot[15:0];
  2:value=sw[0]?{8'd0,store_error}:{5'd0,debug_snapshot[26:16]};
  3:value=sw[0]?file_crc[15:0]:byte_count[15:0];
  4:value=sw[0]?file_crc[31:16]:(status | (s1_healthy?16'd0:16'h8000));
  5:value=sw[0]?memory_crc[15:0]:{12'd0,byte_count[19:16]};
  6:value=sw[0]?memory_crc[31:16]:debug_snapshot[79:64];
  default:value=16'hff00;
 endcase
 wire [15:0] scan_pins;reg [15:0] registered_pins;
 v7_decimal_display u_decimal(.clk(clk_50),.rst_n(key1),.value(value),.mode(sw[0]?2'd1:2'd0),.page(sw[3:1]),.pins(scan_pins));
 always @(posedge clk_50 or negedge key1)if(!key1)registered_pins<=16'hffff;else registered_pins<=scan_pins;
 assign dled=registered_pins;
 assign led={store_error!=0 || captured_mismatch || ctrl_reset_seen || pll_unlock_seen,video_lock,label_ready,s1_healthy};
endmodule
'''
p.write_text(s,encoding='utf-8')
# 沿用TD运行工具；仅移除本位没有实例化的M1 CDC规则。
p=WORK/'project/src/constraints/eth_m6_master.sdc'
s='\n'.join(line for line in p.read_text(encoding='utf-8').splitlines() if 'u_m1_observer/' not in line)+'\n'
s+='set_clock_uncertainty -setup 1.0 [get_clocks {clk_50}]\nset_clock_uncertainty -hold 0.05 [get_clocks {clk_50}]\n'
p.write_text(s,encoding='utf-8')
data=json.loads((OLD/'doc/output/ROUND2_SDC_EXPECTED.json').read_text())
for name in ('false_data_endpoints','mcp_data_endpoints'):
 data[name]=[pin for pin in data[name] if not pin.startswith('u_m1_observer/')]
data['sdc_sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
(WORK/'doc/output/ROUND2_SDC_EXPECTED.json').write_text(json.dumps(data,indent=2)+'\n')
# 原生检查保留S1、PLL和SDRAM；本位没有M1诊断快照寄存器。
p=WORK/'scripts/audit_bist_native.py';s=p.read_text(encoding='utf-8')
a=s.index('constant_m1=[]');b=s.index('sdram=next',a)
s=s[:a]+s[b:]
a=s.index(' for role,names,clock_net in (');b=s.index(' physical_dq=',a)
s=s[:a]+s[b:]
s=s.replace("c['ports']['osclk']==ctrl_clock", "c['ports']['osclk']==network['ports']['refclk']")
s=s.replace('result.update(m1_snapshot_dynamic_register_pairs=snapshot_registers,m1_constant_address_bits=constant_m1,\n              sdram=sdram', 'result.update(sdram=sdram')
p.write_text(s,encoding='utf-8')
for name in ('EG_PHY_SDRAM_2M_32.sv','sd_spi_card_model.sv'):
 shutil.copy2(ROOT/'tb/controlled_loader'/name,WORK/'tb'/name)
shutil.copytree(OLD/'tb/lint',WORK/'tb/lint')
# 模型素材复用旧完整加载回归的冻结输入。
for name in ('controlled_image.memh','label_words.memh'):
 shutil.copy2(A4/'sim/probe_loader'/name,WORK/'tb'/name)
print(WORK)
