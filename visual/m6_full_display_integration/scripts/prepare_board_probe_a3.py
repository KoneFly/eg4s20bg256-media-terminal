"""基于 A2 真卡零进度观测制作 A3 只读计数探针，保留功能路径及封存件。"""
from pathlib import Path
import difflib
import hashlib
import json
import re
import shutil

BASE = Path(__file__).resolve().parents[1]
PREVIOUS = BASE / "experiments/board_0x46_A2_work"
OUT = BASE / "experiments/board_0x46_A3_work"
if OUT.exists():
    raise SystemExit("Refuse overwrite A3")
OUT.mkdir(parents=True)
for directory in ("project", "scripts", "tb", "sim/integration_lint"):
    shutil.copytree(PREVIOUS / directory, OUT / directory,
                    ignore=shutil.ignore_patterns("__pycache__"))
(OUT / "doc/output").mkdir(parents=True)
shutil.copy2(BASE / "doc/output/ROUND2_SDC_EXPECTED.json", OUT / "doc/output/ROUND2_SDC_EXPECTED.json")
for name in ("run_round2_loader.sh", "run_round2_lint.sh", "run_probe_snapshot.sh"):
    shutil.copy2(PREVIOUS / "sim" / name, OUT / "sim" / name)
for path in (OUT / "scripts").iterdir():
    if path.is_file():
        text = re.sub(r"(?<![A-Za-z0-9])A2(?![A-Za-z0-9])", "A3", path.read_text(encoding="utf-8"))
        text = re.sub(r"(?<![A-Za-z0-9])a2(?![A-Za-z0-9])", "a3", text)
        if path.name == "validate_probe_sources.py":
            text = (PREVIOUS / "scripts" / path.name).read_text(encoding="utf-8")
        path.write_text(text
                        .replace("05462", "05463").replace("20261005", "20261006"),
                        encoding="utf-8", newline="\n")
for path in (OUT / "sim").rglob("*.sh"):
    path.write_text(re.sub(r"(?<![A-Za-z0-9])a2(?![A-Za-z0-9])", "a3", path.read_text(encoding="utf-8")), encoding="utf-8", newline="\n")
sources = OUT / "sim/integration_lint/sources.f"
sources.write_text(sources.read_text(encoding="utf-8").replace("board_0x46_A2_work", "board_0x46_A3_work"), encoding="utf-8")

additions = {}
def replace(relative, old, new):
    path = OUT / "project/src" / relative
    text = path.read_text(encoding="utf-8")
    assert text.count(old) == 1, (relative, old)
    path.write_text(text.replace(old, new), encoding="utf-8", newline="\n")
    additions.setdefault(relative, []).append([old, new])

mem = "vendor/fdi_loader/fdi_sdram_cmd_engine.v"
replace(mem, "    output wire [4:0] debug_state,  // 临时只读上板观测\n",
        "    output wire [4:0] debug_state,  // 临时只读上板观测\n    output wire [14:0] debug_count, // A3只读等待计数\n")
replace(mem, "    reg  [14:0] cnt;          // 通用等待计数(25000 < 2^15)\n",
        "    reg  [14:0] cnt;          // 通用等待计数(25000 < 2^15)\n    assign debug_count=cnt;\n")
store = "rtl/fdi_label_store.v"
replace(store, "output wire rd_done,output reg [111:0] debug_snapshot",
        "output wire rd_done,output reg [111:0] debug_snapshot,output wire [44:0] debug_progress")
replace(store, " wire [4:0] debug_reader,debug_mem;\n", " wire [4:0] debug_reader,debug_mem;\n wire [14:0] debug_mem_count;\n assign debug_progress={eng_init,debug_mem_count,watchdog};\n")
replace(store, ".debug_state(debug_mem),", ".debug_state(debug_mem),.debug_count(debug_mem_count),")
hdmi = "rtl/v9_m6_hdmi.v"
replace(hdmi, "    output wire [111:0] label_debug_snapshot,\n",
        "    output wire [111:0] label_debug_snapshot,\n    output wire [44:0] label_debug_progress,\n")
replace(hdmi, ".debug_snapshot(label_debug_snapshot));", ".debug_snapshot(label_debug_snapshot),.debug_progress(label_debug_progress));")
top = "rtl/v9_udp_m6_master_top.v"
replace(top, "    wire [111:0] label_debug_snapshot;\n",
        "    wire [111:0] label_debug_snapshot;\n    wire [44:0] label_debug_progress;\n")
replace(top, "        .label_debug_snapshot(label_debug_snapshot),\n",
        "        .label_debug_snapshot(label_debug_snapshot),.label_debug_progress(label_debug_progress),\n")
path = OUT / "project/src" / top
text = path.read_text(encoding="utf-8")
start = text.index("    // A2：SW0=1临时观测bank")
end = text.index("    wire [15:0] display_value", start)
probe = """    // A3只读启动进度：独立心跳仅由KEY1复位，避免CTRL复位掩盖时钟活动。
    wire [15:0] label_debug_value;
    fdi_clock_progress_probe u_clock_probe(
      .ctrl_clk(ctrl_clk),.key1(key1),.pll_reset(reset_reg),.reset(reset),
      .ctrl_reset_sync(ctrl_reset_sync),.ctrl_rst_n(ctrl_rst_n),
      .progress(label_debug_progress),.status_word(label_debug_snapshot[15:0]),
      .reader_r1_msb(label_debug_snapshot[111]),.page(sw[3:1]),.value(label_debug_value));
"""
replace(top, text[start:end], probe)
replace(top, "wire [15:0] display_value = reset ? 16'd60001 :\n                               sw[0] ? label_debug_value :",
        "wire [15:0] display_value = sw[0] ? label_debug_value :\n                               reset ? 16'd60001 :")
replace(top, "wire [1:0] display_mode = reset ? 2'd3 : sw[0] ? 2'd1 :",
        "wire [1:0] display_mode = sw[0] ? 2'd1 : reset ? 2'd3 :")
module = """
// A3诊断只产生显示值；不向任何加载控制信号反馈。
module fdi_clock_progress_probe(
    input wire ctrl_clk,key1,pll_reset,reset,ctrl_rst_n,
    input wire [1:0] ctrl_reset_sync,input wire [44:0] progress,
    input wire [15:0] status_word,input wire reader_r1_msb,
    input wire [2:0] page,output reg [15:0] value
);
    reg [15:0] raw_ctrl_count;
    always @(posedge ctrl_clk or negedge key1)
        if(!key1)raw_ctrl_count<=0;else raw_ctrl_count<=raw_ctrl_count+16'd1;
    always @(*)case(page)
      0:value=16'd5463;
      1:value=progress[15:0];
      2:value={key1,!pll_reset,ctrl_rst_n,progress[28:16]};
      3:value={progress[44],progress[43:29]};
      4:value=raw_ctrl_count;
      5:value={7'd0,key1,pll_reset,reset,ctrl_reset_sync,ctrl_rst_n,
               reader_r1_msb,status_word[14],status_word[15]};
      6:value=status_word;
      default:value=16'hff00;
    endcase
endmodule
"""
replace(top, "    assign dled=dled_pins;\nendmodule\n", "    assign dled=dled_pins;\nendmodule\n" + module)

guard = json.loads((PREVIOUS / "doc/output/SOURCE_GUARD.json").read_text(encoding="utf-8"))
guard["experiment"] = "A3: A2 functional RTL unchanged; read-only watchdog/memory counters, raw CTRL heartbeat and display calibration"
guard["a3_reverse_to_a2"] = additions
for row in guard["driver_port_reverse_guards"]:
    if row["path"] == mem:
        row["reversible_additions"].extend(additions[mem])
patch = []
for row in guard["source_files"]:
    new = OUT / "project/src" / row["path"]
    old = BASE / "project/src" / row["path"]
    row["after_sha256"] = hashlib.sha256(new.read_bytes()).hexdigest()
    row["changed"] = row["before_sha256"] != row["after_sha256"]
    if row["path"] in additions:
        before = PREVIOUS / "project/src" / row["path"]
        patch.extend(difflib.unified_diff(before.read_text(encoding="utf-8").splitlines(True),
                                         new.read_text(encoding="utf-8").splitlines(True),
                                         fromfile="A2/" + row["path"], tofile="A3/" + row["path"]))
(OUT / "doc/output/SOURCE_GUARD.json").write_text(json.dumps(guard, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(OUT / "doc/output/SOURCE_DIFF.patch").write_text("".join(patch), encoding="utf-8")
validator = OUT / "scripts/validate_probe_sources.py"
text = validator.read_text(encoding="utf-8")
insert = """previous=BASE/'experiments/board_0x46_A2_work/project/src'
for relative,changes in guard['a3_reverse_to_a2'].items():
    restored=(PROBE/'project/src'/relative).read_text(encoding='utf-8')
    for old,new in reversed(changes):
        assert restored.count(new)==1,(relative,new)
        restored=restored.replace(new,old)
    assert restored== (previous/relative).read_text(encoding='utf-8'),relative
"""
text = text.replace("for row in guard['driver_port_reverse_guards']:", insert + "for row in guard['driver_port_reverse_guards']:")
needle = "actual=(PROBE/relative).read_text(encoding='utf-8')\n"
text = text.replace(needle, needle + "for old,new in reversed(guard['a3_reverse_to_a2']['rtl/fdi_label_store.v']):\n    assert actual.count(new)==1\n    actual=actual.replace(new,old)\n")
# 守卫同时绑定已封存A2，不只绑定R2。
needle = "protected=json.loads"
text = text.replace(needle, "a2_index=json.loads((BASE/'doc/output/BOARD_PROBE_A2_EVIDENCE_INDEX.json').read_text(encoding='utf-8'))\nfor row in a2_index['files']:\n    assert sha(BASE/row['path'])==row['sha256'],'原A2封存变化: '+row['path']\n" + needle)
validator.write_text(text, encoding="utf-8", newline="\n")
(OUT / "doc/output/BOARD_PROBE_A3.md").write_text("# A3只读时钟/计数探针\n\n状态：制作中，未生成正式位，硬件待实测。\n\nA2已观测：普通页无60070，BOOT/PWR_UP及d1/d6/d7跨10秒不变。A3保留A2功能路径及MISO两级，只增加只读计数出口、独立KEY1复位的CTRL计数器和临时诊断显示。SW0=1允许在内部reset保持期间观察；SW0=0的原显示优先级保留。\n\nD0=05463；D1=watchdog低16；D2[12:0]=watchdog高13、[13]=ctrl_rst_n、[14]=PLL locked、[15]=key1；D3[14:0]=SDRAM cnt、[15]=eng_init；D4=原始CTRL心跳计数16bit；D5[0]=快照init_ready、[1]=快照eng_init、[2]=快照reader R1 bit7、[3]=ctrl_rst_n、[5:4]=ctrl_reset_sync、[6]=reset、[7]=PLL reset(!locked)、[8]=key1；D6=A2原D1状态字；D7=固定65280校准高位。\n\n所有计数为实时只读，进入ERROR后watchdog停止、原始CTRL心跳仍可变化。心跳独立于CTRL reset，KEY1清零。固定D7不是卡R1。\n", encoding="utf-8")
print(OUT)
