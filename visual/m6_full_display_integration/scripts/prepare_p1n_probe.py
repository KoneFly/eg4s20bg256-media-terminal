"""P1N：P1 独立副本增加只发探针，拒绝覆盖已存在的实验。"""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "experiments/stage_P1_label"
WORK = ROOT / "experiments/stage_P1N_netprobe"
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
assert not WORK.exists(), "拒绝覆盖已有实验"
assert sha(ROOT / "deliverables/M6_FDI_P1_20261008_1BD7CEC0.bit") == "1bd7cec0b1997e7a2aca22d6c81454d8c6bff95b3768656cd83a3e67dea28bcb"
for name in ("project/src", "scripts", "tb", "project/assets"):
    shutil.copytree(BASE / name, WORK / name)
(WORK / "doc/output").mkdir(parents=True)
shutil.copy2(BASE / "doc/output/ROUND2_SDC_EXPECTED.json", WORK / "doc/output/ROUND2_SDC_EXPECTED.json")
for name in ("rgmii_interface.v", "ODDR.v", "IDDR.v"):
    dest = WORK / "project/src/vendor/udp_base/import" / name
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "project/src/vendor/udp_base/import" / name, dest)

def patch(path, pairs):
    text = path.read_text(encoding="utf-8")
    for before, after in pairs:
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    path.write_text(text, encoding="utf-8", newline="\n")

patch(WORK / "project/src/rtl/fdi_sdram_selftest_top.v", [
    (" output wire HDMI_CLK_P", " output wire [3:0] phy1_rgmii_tx_data,output wire phy1_rgmii_tx_ctl,phy1_rgmii_tx_clk,\n output wire HDMI_CLK_P"),
    (" wire pll_reset,ctrl_clk,mem_clk;", " wire pll_reset,ctrl_clk,mem_clk,probe_clk,probe_clk90;"),
    (".clk_125(),.clk_125_90()", ".clk_125(probe_clk),.clk_125_90(probe_clk90)"),
    (" wire pixel_take,label_pixel_valid", " wire raw_video_pll_lock,raw_video_link_lock;wire [31:0] probe_frame_gray;\n wire pixel_take,label_pixel_valid"),
    ("  .pixel_take(pixel_take),.pixel_data", "  .raw_pll_lock(raw_video_pll_lock),.raw_link_lock(raw_video_link_lock),.probe_frame_gray(probe_frame_gray),\n  .pixel_take(pixel_take),.pixel_data"),
    ("  0:value=16'd5480;", "  0:value=16'd5481;"),
    (" wire [15:0] scan_pins;", """ // 探针只消费既有调试出口；功能反馈与已验加载器保持原样。
 wire [319:0] probe_base={memory_crc,file_crc,{11'd0,rd_req_addr},
  {8'd0,debug_progress[44],label_shown,pixel_ready,label_pixel_valid,rd_done,rd_beat_valid,rd_req_ready,rd_req_valid},
  status,flags,stream_error,store_error,{4'd0,store_state},{1'd0,debug_progress[43:29]},
  debug_snapshot,{3'd0,debug_progress[28:0]}};
 fdi_net_probe u_probe(.base_clk(clk_50),.tx_clk(probe_clk),.tx_clk90(probe_clk90),.key1(key1),
  .base_live(probe_base),.frame_gray(probe_frame_gray),.video_pll_lock(raw_video_pll_lock),
  .pixel_reset(pixel_rst),.video_link_lock(raw_video_link_lock),.network_lock(!pll_reset),
  .rgmii_txd(phy1_rgmii_tx_data),.rgmii_tx_ctl(phy1_rgmii_tx_ctl),.rgmii_txc(phy1_rgmii_tx_clk));
 wire [15:0] scan_pins;"""),
])
patch(WORK / "project/src/rtl/fdi_label_video.v", [
    (" output wire pixel_take", " output wire raw_pll_lock,raw_link_lock,output wire [31:0] probe_frame_gray,\n output wire pixel_take"),
    (" assign video_lock=video_sync;", """ // 只读帧计数不随像素域复位清除，以保留失锁前后的进展。
 reg [31:0] probe_frames;
 reg [31:0] probe_gray;
 always @(posedge pixel_clk or negedge key1)
  if(!key1)begin probe_frames<=0;probe_gray<=0;end
  else if(!pixel_rst && h==0 && v==0)begin
   probe_frames<=probe_frames+32'd1;
   probe_gray<=((probe_frames+32'd1)>>1)^(probe_frames+32'd1);
  end
 assign probe_frame_gray=probe_gray;
 assign raw_pll_lock=pll_locked;
 assign raw_link_lock=raw_video_lock;
 assign video_lock=video_sync;"""),
])

adc = WORK / "project/src/constraints/eth_m6_master.adc"
tx_lines = [line for line in (ROOT / "project/src/constraints/eth_m6_master.adc").read_text(encoding="utf-8").splitlines()
            if line.startswith("set_pin_assignment {phy1_rgmii_tx")]
assert len(tx_lines) == 6
adc.write_text(adc.read_text(encoding="utf-8") + "\n# P1N只发探针：沿用052已验发送脚。\n" + "\n".join(tx_lines) + "\n", encoding="utf-8", newline="\n")

# 先保留完整原约束；新握手总线在综合后按真实存活FF逐位生成MC4/3。
new_false = [f"u_probe/{name}_reg.d" for name in
             ("req_meta", "ack_meta", "vpll_meta", "prst_meta", "vlink_meta", "nlock_meta")]
new_false += [f"u_probe/frame_meta_reg[{i}].d" for i in range(32)]
sdc = WORK / "project/src/constraints/eth_m6_master.sdc"
sdc.write_text(sdc.read_text(encoding="utf-8") + "\n# P1N新增CDC：只豁免首级D端。\n" +
               "".join(f"set_false_path -to [get_pins {{{p}}}]\n" for p in new_false) +
               "# 125MHz发送时钟与052相同；ODDR双沿发数据，90度时钟转发。\n" +
               "set_clock_uncertainty -setup 0.2 [get_clocks {u_clk/u_pll_0/pll_inst.clkc[0]}]\n" +
               "set_clock_uncertainty -hold 0.05 [get_clocks {u_clk/u_pll_0/pll_inst.clkc[0]}]\n",
               encoding="utf-8", newline="\n")
expected_path = WORK / "doc/output/ROUND2_SDC_EXPECTED.json"
expected = json.loads(expected_path.read_text(encoding="utf-8"))
expected["false_data_endpoints"] += new_false
expected["sdc_sha256"] = sha(sdc)
expected_path.write_text(json.dumps(expected, indent=2) + "\n", encoding="utf-8")

# 新过程文件全部落到D盘ASCII目录，不修改已有阶段或系统环境变量。
patch(WORK / "scripts/run_m1.ps1", [
    ('Join-Path ([IO.Path]::GetTempPath())', 'Join-Path "D:/Temp/fdi_p1n"'),
])
patch(WORK / "scripts/audit_round2_cdc.py", [
    ("clock != expected['mcp_source_clock']", "clock != expected.get('mcp_source_clocks',{}).get(target,expected['mcp_source_clock'])"),
])
patch(WORK / "scripts/remap_physical_sdc.py", [
    ("'u_label_stream/clk':'clk_50','u_store/clk':'clk_50'", "'u_label_stream/clk':'clk_50','u_store/clk':'clk_50',\n                'u_probe/base_clk':'clk_50',\n                'u_probe/tx_clk':'u_clk/u_pll_0/pll_inst.clkc[0]'"),
    ("record['untimed_hardmacro_endpoints']=", "record['mcp_source_clocks']={end:expected.get('mcp_source_clocks',{}).get(p,expected['mcp_source_clock']) for p in expected['mcp_data_endpoints'] for end in mapped[p]['physical_pins']}\nrecord['untimed_hardmacro_endpoints']="),
])

changed = {"rtl/fdi_sdram_selftest_top.v", "rtl/fdi_label_video.v", "constraints/eth_m6_master.adc", "constraints/eth_m6_master.sdc"}
baseline = [dict(path=p.relative_to(BASE / "project/src").as_posix(), sha256=sha(p))
            for p in sorted((BASE / "project/src").rglob("*")) if p.is_file()]
for row in baseline:
    if row["path"] not in changed:
        assert sha(WORK / "project/src" / row["path"]) == row["sha256"], row["path"]
(WORK / "doc/output/P1N_BASELINE.json").write_text(json.dumps(dict(
    baseline="P1_1BD7CEC0_HW_FAILED", readonly_baseline=str(BASE),
    changed_baseline_files=sorted(changed), baseline_files=baseline,
    hardware_status="NOT_STARTED", probe_version=5481,
    temp_root="D:/Temp/fdi_p1n", burn_index_owner="user_or_spec_owner"), indent=2) + "\n", encoding="utf-8")
print(WORK)
