"""P1静态线稿：在真板已验L1上只增加SDRAM标签读出→HDMI显示，其余L1源逐字节不变。"""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'experiments/label_debug_L1'
FULL = ROOT / 'experiments/full_observe_F7'
WORK = ROOT / 'experiments/stage_P1_label'
assert not WORK.exists(), '拒绝覆盖已有实验'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
for folder in ('project/src', 'scripts', 'tb', 'doc/output'):
    shutil.copytree(BASE / folder, WORK / folder)
(WORK / 'sim').mkdir()
# 标签读出与像素FIFO沿用完整工程同一份源，不另写。
shutil.copy2(FULL / 'project/src/rtl/fdi_label_stream.v', WORK / 'project/src/rtl/fdi_label_stream.v')
shutil.copytree(FULL / 'project/src/vendor/fdi_stream', WORK / 'project/src/vendor/fdi_stream')
(WORK / 'project/assets').mkdir()
shutil.copy2(FULL / 'project/assets/rom_row_span.hex', WORK / 'project/assets/rom_row_span.hex')

(WORK / 'project/src/rtl/fdi_label_video.v').write_text('''`timescale 1ns/1ps
// 标签直出：像素FIFO预填后自帧首开放读取，标签RGB565原样送HDMI；
// 开放前显示彩条(加载未完成)，开放后FIFO失效显示纯红(读出链故障)。
module fdi_label_video(
 input wire clk,key1,reset,
 output wire pixel_clk,pixel_rst,video_lock,video_pll_lock,label_shown,
 output wire pixel_take,input wire [31:0] pixel_data,input wire pixel_ready,
 output wire HDMI_CLK_P,HDMI_D0_P,HDMI_D1_P,HDMI_D2_P,HDMI_DDC_SCL,inout wire HDMI_DDC_SDA
);
 wire serial_clk,pll_locked;
 hdmi_pll u_pll(.ref_clk(clk),.pll_rst_n(!reset),.pixel_clk(pixel_clk),.serial_clk(serial_clk),.audio_mclk(),.pll_locked(pll_locked));
 wire pixel_arst=reset || !pll_locked;
 reg [1:0] pixel_reset_sync;
 always @(posedge pixel_clk or posedge pixel_arst)
  if(pixel_arst)pixel_reset_sync<=2'b11;else pixel_reset_sync<={pixel_reset_sync[0],1'b0};
 assign pixel_rst=pixel_reset_sync[1];
 reg [9:0] h,v;
 reg enabled;
 always @(posedge pixel_clk or posedge pixel_rst)begin
  if(pixel_rst)begin h<=0;v<=0;enabled<=0;end
  else begin
   if(h==10'd799)begin h<=0;if(v==10'd524)v<=0;else v<=v+10'd1;end
   else h<=h+10'd1;
   // 只在整帧读窗之前开放，保证首个读出像素对应屏幕左上角。
   if(h==10'd0 && v==10'd0 && pixel_ready)enabled<=1'b1;
  end
 end
 wire de=h>=10'd144 && h<10'd784 && v>=10'd35 && v<10'd515;
 wire vs=v>=10'd2;
 // FIFO输出为寄存数据，读取比显示提前一拍。
 assign pixel_take=enabled && h>=10'd143 && h<10'd783 && v>=10'd35 && v<10'd515;
 wire [15:0] label=pixel_data[31:16];
 wire [23:0] label888={label[15:11],label[15:13],label[10:5],label[10:9],label[4:0],label[4:2]};
 wire [23:0] bars={{8{h[7]}},{8{h[8]}},{8{h[9]}}};
 wire [23:0] rgb=!enabled ? bars : pixel_ready ? label888 : 24'hff0000;
 wire axis_ready,axis_valid,axis_last,axis_user;wire [23:0] axis_data;
 axis_pixel_adapter u_axis(.I_clk(pixel_clk),.I_rst(pixel_rst),.I_vs(vs),.I_de(de),.pixel_valid(de),
  .pixel_rgb888(rgb),.axis_s_ready(axis_ready),.axis_s_user(axis_user),.axis_s_valid(axis_valid),.axis_s_last(axis_last),.axis_s_data(axis_data));
 reg [16:0] edid_count;
 always @(posedge pixel_clk)if(pixel_rst)edid_count<=0;else if(edid_count<100000)edid_count<=edid_count+1'b1;
 wire [9:0] ch0,ch1,ch2,chclk;wire raw_video_lock;
 hdmi_1_4b_transmitter_core_wrapper #(.DEVICE("EG"),.HTOTAL(800),.HSA(96),.HFP(16),.HBP(48),.HACTIVE(640),
  .VTOTAL(525),.VSA(2),.VFP(10),.VBP(33),.VACTIVE(480),.VIDEO_TPG("Disable"),.VIDEO_FORMAT("RGB"),.VIDEO_VIC(1),
  .AUDIO_SAMPLE_RATE("48K"),.IIC_SCL_DIV(250)) u_hdmi(
  .I_pixel_clk(pixel_clk),.I_rst(pixel_rst),.I_edid_read_trig(edid_count==99999),.O_edid_read_valid(),.O_edid_read_data(),
  .I_axis_s_user(axis_user),.I_axis_s_valid(axis_valid),.I_axis_s_last(axis_last),.I_axis_s_data(axis_data),.O_axis_s_ready(axis_ready),
  .I_audio_valid(1'b0),.I_audio_left_data(24'd0),.I_audio_right_data(24'd0),.I_acr_valid(1'b0),.I_acr_cts(20'd0),.I_acr_n(20'd0),
  .O_video_locked(raw_video_lock),.O_ddc_scl(HDMI_DDC_SCL),.IO_ddc_sda(HDMI_DDC_SDA),
  .O_ch0_tmds_data(ch0),.O_ch1_tmds_data(ch1),.O_ch2_tmds_data(ch2),.O_clk_tmds_data(chclk));
 hdmi_phy_wrapper #(.DEVICE("EG")) u_phy(.I_pixel_clk(pixel_clk),.I_serial_clk(serial_clk),.I_rst(pixel_rst),
  .I_tmds_channel_0(ch0),.I_tmds_channel_1(ch1),.I_tmds_channel_2(ch2),.I_tmds_channel_clk(chclk),
  .O_tmds_ch0_p(HDMI_D0_P),.O_tmds_ch1_p(HDMI_D1_P),.O_tmds_ch2_p(HDMI_D2_P),.O_tmds_clk_p(HDMI_CLK_P));
 (* ASYNC_REG="TRUE" *) reg video_meta,video_sync,pll_meta,pll_sync,shown_meta,shown_sync;
 always @(posedge clk or negedge key1)
  if(!key1)begin video_meta<=0;video_sync<=0;pll_meta<=0;pll_sync<=0;shown_meta<=0;shown_sync<=0;end
  else begin
   video_meta<=raw_video_lock;video_sync<=video_meta;pll_meta<=pll_locked;pll_sync<=pll_meta;
   shown_meta<=enabled && pixel_ready;shown_sync<=shown_meta;
  end
 assign video_lock=video_sync;
 assign video_pll_lock=pll_sync;
 assign label_shown=shown_sync;
endmodule
''', encoding='utf-8')


def patch(path, pairs):
    text = path.read_text(encoding='utf-8')
    for before, after in pairs:
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    path.write_text(text, encoding='utf-8')


top = WORK / 'project/src/rtl/fdi_sdram_selftest_top.v'
patch(top, [
    (''' wire pixel_clk,video_lock,video_pll_lock;
 fdi_fixed_video u_video(.clk(clk_50),.key1(key1),.reset(reset),.pixel_clk(pixel_clk),.video_lock(video_lock),.video_pll_lock(video_pll_lock),''',
     ''' wire pixel_clk,pixel_rst,video_lock,video_pll_lock,label_shown;
 wire pixel_take,label_pixel_valid,pixel_ready;wire [31:0] pixel_data;
 fdi_label_video u_video(.clk(clk_50),.key1(key1),.reset(reset),.pixel_clk(pixel_clk),.pixel_rst(pixel_rst),
  .video_lock(video_lock),.video_pll_lock(video_pll_lock),.label_shown(label_shown),
  .pixel_take(pixel_take),.pixel_data(pixel_data),.pixel_ready(pixel_ready),'''),
    (''' wire [44:0] debug_progress;wire [3:0] store_state;wire [31:0] store_crc;''',
     ''' wire [44:0] debug_progress;wire [3:0] store_state;wire [31:0] store_crc;
 wire rd_req_valid,rd_req_ready,rd_beat_valid,rd_done;wire [20:0] rd_req_addr,rd_beat_addr;
 wire [31:0] rd_beat_data;wire [7:0] stream_error;
 fdi_label_stream u_label_stream(.clk(clk_50),.rst_n(store_rst_n),.label_ready(label_ready),
  .rd_req_valid(rd_req_valid),.rd_req_addr(rd_req_addr),.rd_req_ready(rd_req_ready),
  .rd_beat_valid(rd_beat_valid),.rd_beat_data(rd_beat_data),.rd_beat_addr(rd_beat_addr),.rd_done(rd_done),
  .pixel_clk(pixel_clk),.pixel_rst(pixel_rst),.pixel_take(pixel_take),
  .pixel_data(pixel_data),.pixel_valid(label_pixel_valid),.pixel_ready(pixel_ready),.error_code(stream_error));'''),
    (''' .label_ready(label_ready),.error_code(store_error),.rd_req_valid(1'b0),.rd_req_addr(21'h40000),
  .rd_req_ready(),.rd_beat_valid(),.rd_beat_data(),.rd_beat_addr(),.rd_done(),''',
     ''' .label_ready(label_ready),.error_code(store_error),.rd_req_valid(rd_req_valid),.rd_req_addr(rd_req_addr),
  .rd_req_ready(rd_req_ready),.rd_beat_valid(rd_beat_valid),.rd_beat_data(rd_beat_data),.rd_beat_addr(rd_beat_addr),.rd_done(rd_done),'''),
    ("  0:value=16'd5469;", "  0:value=16'd5480;"),
    ("  default:value=16'hff00;", "  default:value=sw[0]?{stream_error,7'd0,label_shown}:16'hff00;"),
])

# 新增跨域只有像素FIFO格雷指针、预填/故障同步及显示开放同步，各豁免首级D端。
new_false = ([f'u_label_stream/u_fifo/rd_gray_w1_reg[{i}].d' for i in range(11)] +
             [f'u_label_stream/u_fifo/wr_gray_r1_reg[{i}].d' for i in range(11)] +
             ['u_label_stream/start_meta_reg.d', 'u_label_stream/ctrl_fault_meta_reg.d',
              'u_label_stream/pixel_fault_meta_reg.d', 'u_video/shown_meta_reg.d'])
sdc = WORK / 'project/src/constraints/eth_m6_master.sdc'
text = sdc.read_text(encoding='utf-8')
anchor = '\n# TF1基准50MHz域'
assert text.count(anchor) == 1
text = text.replace(anchor, '\n# P1标签读出跨域：仅首级同步D端。\n' +
                    ''.join(f'set_false_path -to [get_pins {{{p}}}]\n' for p in new_false) + anchor)
sdc.write_text(text, encoding='utf-8')
expected_path = WORK / 'doc/output/ROUND2_SDC_EXPECTED.json'
expected = json.loads(expected_path.read_text(encoding='utf-8'))
expected['false_data_endpoints'] += new_false
expected['sdc_sha256'] = sha(sdc)
expected_path.write_text(json.dumps(expected, indent=2) + '\n', encoding='utf-8')

# 行区段ROM头文件须在TD工作目录可见，与完整工程流程一致。
run = WORK / 'scripts/run_m1.ps1'
patch(run, [('Copy-Item -LiteralPath "$s1Task/project/src/constraints/eth_m6_master.sdc" -Destination "$s1Stage/production.sdc"',
             'Copy-Item -LiteralPath "$s1Task/project/src/constraints/eth_m6_master.sdc" -Destination "$s1Stage/production.sdc"\n'
             'Copy-Item -LiteralPath "$s1Task/project/src/vendor/fdi_stream/fdi_row_span_rom.vh" -Destination "$s1Stage/fdi_row_span_rom.vh"')])

(WORK / 'tb/tb_p1.sv').write_text('''`timescale 1ns/1ps
// 实际P1顶层：加载完成后连续两帧逐像素核对屏幕输出与标签金值(含行区段留黑)。
module tb_p1;
 reg clk_50=0;always #10 clk_50=~clk_50;
 reg key1=0;reg [3:0] sw=0;wire [3:0] led;wire [15:0] dled;
 wire sd_ncs,sd_dclk,sd_mosi,sd_miso;
 wire HDMI_CLK_P,HDMI_D0_P,HDMI_D1_P,HDMI_D2_P,HDMI_DDC_SCL,HDMI_DDC_SDA;
 fdi_sdram_selftest_top dut(.*);
 sd_spi_card_model #(.IMG_SECTORS(4096)) card(
  .spi_cs_n(sd_ncs),.spi_sck(sd_dclk),.spi_mosi(sd_mosi),.spi_miso(sd_miso));
 `include "fdi_row_span_rom.vh"
 reg [31:0] golden[0:153599];
 always @(clk_50)begin force dut.ctrl_clk=clk_50;force dut.mem_clk=~clk_50;end
 function [23:0] expect_rgb(input [9:0] x,input [8:0] y);
  reg [19:0] span;reg [31:0] word;reg [15:0] p;
  begin
   span=fdi_row_span(y);word=golden[(479-y)*320+x[9:1]];
   p=(y>=451 || x<span[19:10] || x>span[9:0]) ? 16'd0 : (x[0] ? word[31:16] : word[15:0]);
   expect_rgb={p[15:11],p[15:13],p[10:5],p[10:9],p[4:0],p[4:2]};
  end
 endfunction
 integer frames=0,checked=0,lit=0;reg started=0;
 always @(posedge dut.pixel_clk)begin
  if(dut.u_video.h==0 && dut.u_video.v==35 && dut.u_video.enabled)begin
   if(started)frames<=frames+1;started<=1;
  end
  if(started && dut.u_video.de)begin
   assert(dut.u_video.pixel_ready)else $fatal(1,"FIFO lost ready x=%0d y=%0d",dut.u_video.h-144,dut.u_video.v-35);
   assert(dut.u_video.rgb==expect_rgb(dut.u_video.h-10'd144,dut.u_video.v-10'd35))
    else $fatal(1,"pixel x=%0d y=%0d got %h expected %h",dut.u_video.h-144,dut.u_video.v-35,dut.u_video.rgb,
                expect_rgb(dut.u_video.h-10'd144,dut.u_video.v-10'd35));
   checked<=checked+1;if(dut.u_video.rgb!=0)lit<=lit+1;
  end
 end
 initial begin
  force dut.pll_reset=0;
  $readmemh("label_words.memh",golden);
  repeat(4)@(negedge clk_50);key1=1;
  wait(dut.label_ready || dut.store_error!=0);
  assert(dut.label_ready)else $fatal(1,"load error %h",dut.store_error);
  wait(frames==2);
  @(negedge clk_50);
  assert(checked==2*640*480 && lit>0)else $fatal(1,"checked=%0d lit=%0d",checked,lit);
  assert(dut.stream_error==0 && dut.store_error==0)else $fatal(1,"errors stream=%h store=%h",dut.stream_error,dut.store_error);
  repeat(8)@(negedge clk_50);
  sw=4'b1111;#40;assert(dut.value==16'd1)else $fatal(1,"page7 %h",dut.value);
  sw=4'b0001;#40;assert(dut.value==16'd5480)else $fatal(1,"page0 %0d",dut.value);
  $display("P1_PASS frames=2 pixels=%0d lit=%0d fileCRC=%h memoryCRC=%h time=%0t",checked,lit,dut.file_crc,dut.memory_crc,$time);
  $finish;
 end
 initial begin #2000000000;$fatal(1,"P1 timeout state=%0d code=%h",dut.store_state,dut.store_error);end
endmodule
''', encoding='utf-8')
(WORK / 'sim/run_p1.sh').write_text('''#!/usr/bin/env bash
set -euo pipefail
pkg=$(cd -- "$(dirname -- "$0")/.." && pwd)
out="$pkg/sim/p1"
mkdir -p "$out/src"
cp "$pkg/project/src/rtl/"*.v "$pkg/project/src/vendor/fdi_loader/"*.v "$pkg/project/src/vendor/fdi_stream/"*.v "$out/src/"
cp "$pkg/project/src/vendor/udp_base/ip/pll_gen.v" "$pkg/project/src/vendor/display020/hdmi_pll.v" "$pkg/project/src/vendor/display020/axis_pixel_adapter.v" "$out/src/"
cp "$pkg/tb/tb_p1.sv" "$pkg/tb/sd_spi_card_model.sv" "$pkg/tb/EG_PHY_SDRAM_2M_32.sv" "$pkg/tb/lint/boundary_stubs.sv" "$out/src/"
rm -f "$out/src/fdi_fixed_video.v"
python3 - "$pkg/tb/lint/primitive_interfaces.v" "$out/src/primitive_interfaces.v" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
s,n=re.subn(r'module EG_PHY_SDRAM_2M_32\\b.*?endmodule','',s,flags=re.S)
assert n==1
Path(sys.argv[2]).write_text(s)
PY
cp "$pkg/tb/controlled_image.memh" "$pkg/tb/label_words.memh" "$out/"
cd "$out"
verilator --binary --assert --timing --language 1364-2005 +1800-2017ext+sv -Wno-fatal -DSIMULATION -j 4 \\
 -I"$pkg/project/src/vendor/fdi_stream" --top-module tb_p1 src/*.v src/*.sv > build.log 2>&1
./obj_dir/Vtb_p1 > run.log 2>&1
grep P1_PASS run.log
''', encoding='utf-8', newline='\n')

patch(WORK / 'scripts/remap_physical_sdc.py', [("                'u_decimal/clk':'clk_50','u_ctrl_meter/base_clk':'clk_50'}", "                'u_decimal/clk':'clk_50','u_ctrl_meter/base_clk':'clk_50',\n                # P1新增标签读出两侧的物理时钟网名。\n                'u_label_stream/pixel_clk':'u_video/u_pll/u_video_pll.clkc[0]',\n                'u_video/pixel_clk':'u_video/u_pll/u_video_pll.clkc[0]',\n                'u_label_stream/clk':'clk_50','u_store/clk':'clk_50'}")])

patch(WORK / 'scripts/prepare_m1.py', [('    commands += ["set_param route hold_fix_iteration 20", "fix_hold -clock_opt -eco", "update_timing -mode final"]', '    # 默认时钟优化；MISO输入口余量不足时改插缓冲，与L1真实网表MISO保持缓冲同类。\n    import os\n    hold_cmd = "fix_hold -buffer_opt -eco" if os.environ.get("FDI_HOLD") == "buffer" else "fix_hold -clock_opt -eco"\n    commands += ["set_param route hold_fix_iteration 20", hold_cmd, "update_timing -mode final"]')])

frozen = {p.relative_to(BASE / 'project/src').as_posix() for p in (BASE / 'project/src').rglob('*') if p.is_file()}
changed = {'rtl/fdi_sdram_selftest_top.v', 'constraints/eth_m6_master.sdc'}
for rel in frozen - changed:
    assert sha(BASE / 'project/src' / rel) == sha(WORK / 'project/src' / rel), rel
print(WORK)
