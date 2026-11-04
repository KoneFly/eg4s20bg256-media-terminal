"""在已验P1N独立副本上仅增加底部128柱测试图案，拒绝覆盖已有实验。"""
from pathlib import Path
import hashlib,json,shutil

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/"experiments/stage_P1N_netprobe"
WORK=ROOT/"experiments/stage_P2_test128"
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert not WORK.exists(),"拒绝覆盖已有实验"
bit=ROOT/"deliverables/M6_FDI_P1N_20261008_6AD3D8CE.bit"
assert sha(bit)=="6ad3d8ce58418b8e340fe412cd3f64c47159d6fb5cc3d093ce8f5d3889ef343f"
manifest=json.loads((BASE/"td_run/bit_p1n_r2/SOURCE_MANIFEST.json").read_text(encoding="utf-8"))
for row in manifest["files"]:assert sha(BASE/"project/src"/row["path"])==row["sha256"],row["path"]
for folder in ("project","tb"):
    shutil.copytree(BASE/folder,WORK/folder)
(WORK/"scripts").mkdir()
(WORK/"doc/output").mkdir(parents=True)
for name in ("run_m1.ps1","prepare_m1.py","read_m1.py","remap_physical_sdc.py",
             "audit_bist_native.py","audit_round2_cdc.py","check_lint_seal.py","check_archive_seal.py",
             "decode_p1n.py","capture_p1n.ps1","check_probe_tools.py"):
    shutil.copy2(BASE/"scripts"/name,WORK/"scripts"/name)
shutil.copy2(BASE/"scripts/lint_p1n.py",WORK/"scripts/lint_p2.py")
shutil.copy2(BASE/"doc/output/ROUND2_SDC_EXPECTED.json",WORK/"doc/output/ROUND2_SDC_EXPECTED.json")

def patch(path,pairs):
    text=path.read_text(encoding="utf-8")
    for before,after in pairs:
        assert text.count(before)==1,(path,before)
        text=text.replace(before,after)
    path.write_text(text,encoding="utf-8",newline="\n")

patch(WORK/"project/src/rtl/fdi_sdram_selftest_top.v",[
    ("  0:value=16'd5481;","  0:value=16'd5482;"),
    (" fdi_net_probe u_probe("," fdi_net_probe #(.DIAG_VERSION(16'd5482)) u_probe("),
])
patch(WORK/"project/src/rtl/fdi_label_video.v",[
    (" reg [9:0] h,v;"," reg [9:0] h,v;\n reg [31:0] probe_frames;"),
    (" wire [23:0] rgb=!enabled ? bars : pixel_ready ? label888 : 24'hff0000;", """ wire [23:0] test_rgb;
 fdi_test128_bars u_test128(.clk(pixel_clk),.reset(pixel_rst),.h(h),.v(v),
  .frame_tag(probe_frames[8:0]),.background(label888),.rgb(test_rgb));
 wire [23:0] rgb=!enabled ? bars : pixel_ready ? test_rgb : 24'hff0000;"""),
    (" reg [31:0] probe_frames;\n reg [31:0] probe_gray;"," reg [31:0] probe_gray;"),
])
patch(WORK/"project/src/rtl/fdi_net_probe.v",[
    (" parameter [16:0] PERIOD_CYCLES=17'd125000", " parameter [15:0] DIAG_VERSION=16'd5481,\n parameter [16:0] PERIOD_CYCLES=17'd125000"),
    ("milliseconds,sequence_number,16'd5481,frame_flags", "milliseconds,sequence_number,DIAG_VERSION,frame_flags"),
])
for name in ("remap_physical_sdc.py","audit_bist_native.py"):
    patch(WORK/"scripts"/name,[("check_p1n_r2/gate_netlist.v","check_p2/gate_netlist.v")])
patch(WORK/"scripts/lint_p2.py",[
    ('BASE = WORK.parent / "stage_P1_label"','BASE = WORK.parent / "stage_P1N_netprobe"'),
    ('doc/output/P1N_LINT.json','doc/output/P2_LINT.json'),
])
patch(WORK/"scripts/check_lint_seal.py",[("doc/output/P1N_LINT.json","doc/output/P2_LINT.json")])
patch(WORK/"scripts/check_archive_seal.py",[("doc/output/P1N_DELIVERY.json","doc/output/P2_DELIVERY.json")])
patch(WORK/"scripts/run_m1.ps1",[('"D:/Temp/fdi_p1n"','"D:/Temp/fdi_p2"')])
# 报文布局和源MAC保留，只让版本字准确区分P1N/P2。
patch(WORK/"scripts/decode_p1n.py",[
    ('FIELDS = ["pc_time_s",','FIELDS = ["version","pc_time_s",'),
    ('int.from_bytes(p[6:8],"little")!=5481','int.from_bytes(p[6:8],"little") not in (5481,5482)'),
    ('return dict(sequence=word(8),','return dict(version=int.from_bytes(p[6:8],"little"),sequence=word(8),'),
])
baseline=dict(date="2026-10-08",maintainer="Codex",baseline="P1N_HW_FIRST_DISPLAY_5MIN",
              baseline_bit_sha256=sha(bit),baseline_tree=str(BASE.resolve()),
              changed_baseline_files=["rtl/fdi_sdram_selftest_top.v","rtl/fdi_label_video.v","rtl/fdi_net_probe.v"],
              baseline_files=manifest["files"],source_manifest_sha256=sha(BASE/"td_run/bit_p1n_r2/SOURCE_MANIFEST.json"),
              constraints_unchanged=True,adc_unchanged=True,hardware_status="NOT_STARTED",
              scope="仅128柱测试；不插GCLK、不接W2/S2、RX或真实频谱；保留原网口探针布局和原约束")
(WORK/"doc/output/P2_BASELINE.json").write_text(json.dumps(baseline,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
for row in manifest["files"]:
    if row["path"] not in baseline["changed_baseline_files"]:assert sha(WORK/"project/src"/row["path"])==row["sha256"],row["path"]
print(json.dumps(dict(work=WORK.name,baseline_sha256=sha(bit),version=5482,unchanged_constraints=True)))
