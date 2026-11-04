"""在隔离副本中增加A4只读事件锁存，不改功能计数器或驱动。"""
from pathlib import Path
import difflib
import hashlib
import json
import shutil

BASE = Path(__file__).resolve().parents[1]
PREVIOUS = BASE / "experiments/board_0x46_A3_work"
OUT = BASE / "experiments/board_0x46_A4_work"
assert not OUT.exists(), "Refuse overwrite A4"
for entry in json.loads((BASE / "doc/output/BOARD_PROBE_A3_EVIDENCE_INDEX.json").read_text(encoding="utf-8"))["files"]:
    assert hashlib.sha256((BASE / entry["path"]).read_bytes()).hexdigest() == entry["sha256"]
for directory in ("project", "scripts", "tb", "sim/integration_lint"):
    shutil.copytree(PREVIOUS / directory, OUT / directory, ignore=shutil.ignore_patterns("__pycache__", "audit_clock_probe.py"))
(OUT / "doc/output").mkdir(parents=True)
for name in ("run_round2_loader.sh", "run_round2_lint.sh", "run_probe_snapshot.sh", "run_clock_progress.sh"):
    p = OUT / "sim" / name
    p.write_text((PREVIOUS / "sim" / name).read_text(encoding="utf-8").replace("board_0x46_A3_work", "board_0x46_A4_work"), encoding="utf-8", newline="\n")
for p in (OUT / "scripts").iterdir():
    if p.is_file() and p.name != "validate_probe_sources.py":
        p.write_text(p.read_text(encoding="utf-8").replace("board_0x46_A3_work", "board_0x46_A4_work"), encoding="utf-8", newline="\n")
p = OUT / "sim/integration_lint/sources.f"
p.write_text(p.read_text(encoding="utf-8").replace("board_0x46_A3_work", "board_0x46_A4_work"), encoding="utf-8")
shutil.copy2(PREVIOUS / "doc/output/ROUND2_SDC_EXPECTED.json", OUT / "doc/output/ROUND2_SDC_EXPECTED.json")
relative = "rtl/v9_udp_m6_master_top.v"
p = OUT / "project/src" / relative
old = p.read_text(encoding="utf-8")
assert old.count(".ctrl_clk(ctrl_clk),.key1(key1),.pll_reset(reset_reg)") == 1
new = old.replace(".ctrl_clk(ctrl_clk),.key1(key1),.pll_reset(reset_reg)", ".ctrl_clk(ctrl_clk),.base_clk(clk_50),.key1(key1),.pll_reset(reset_reg)")
start = new.index("// A3诊断只产生显示值")
new = new[:start] + '''// A4只读事件观测：位历史和复位重现只影响临时显示，不向功能路径反馈。
module fdi_clock_progress_probe(
    input wire ctrl_clk,base_clk,key1,pll_reset,reset,ctrl_rst_n,
    input wire [1:0] ctrl_reset_sync,input wire [44:0] progress,
    input wire [15:0] status_word,input wire reader_r1_msb,
    input wire [2:0] page,output reg [15:0] value
);
    // 按位OR历史不是数值最大值：某位为1仅表示该计数位曾采样为1。
    reg [28:0] ever_watchdog;
    reg start_seen,boot_exit_seen,low_wrap_seen,ctrl_edge_seen,bad_state_seen;
    reg previous_bit15;
    always @(posedge ctrl_clk or negedge key1)begin
        if(!key1)begin
            ever_watchdog<=0;start_seen<=0;boot_exit_seen<=0;low_wrap_seen<=0;
            ctrl_edge_seen<=0;bad_state_seen<=0;previous_bit15<=0;
        end else begin
            ever_watchdog<=ever_watchdog | progress[28:0];
            start_seen<=start_seen || progress[28:0]==29'd499999;
            boot_exit_seen<=boot_exit_seen || status_word[3:0]!=0;
            low_wrap_seen<=low_wrap_seen || (previous_bit15 && !progress[15] && status_word[3:0]==0);
            ctrl_edge_seen<=1;
            bad_state_seen<=bad_state_seen || status_word[3:0]>11;
            previous_bit15<=progress[15];
        end
    end
    // 基准50MHz域独立锁存运行后的复位重现；短于采样窗口的脉冲仍可能漏采。
    reg [1:0] ctrl_rst_sample,pll_rst_sample;
    reg reset_monitor_armed,ctrl_reset_seen,pll_unlock_seen;
    always @(posedge base_clk or negedge key1)begin
        if(!key1)begin
            ctrl_rst_sample<=0;pll_rst_sample<=3;reset_monitor_armed<=0;
            ctrl_reset_seen<=0;pll_unlock_seen<=0;
        end else begin
            ctrl_rst_sample<={ctrl_rst_sample[0],ctrl_rst_n};
            pll_rst_sample<={pll_rst_sample[0],pll_reset};
            if(ctrl_rst_sample[1] && !pll_rst_sample[1])reset_monitor_armed<=1;
            if(reset_monitor_armed)begin
                ctrl_reset_seen<=ctrl_reset_seen || !ctrl_rst_sample[1];
                pll_unlock_seen<=pll_unlock_seen || pll_rst_sample[1];
            end
        end
    end
    always @(*)case(page)
      0:value=16'd5464;
      1:value=ever_watchdog[15:0];
      2:value={key1,!pll_reset,ctrl_rst_n,ever_watchdog[28:16]};
      3:value={progress[44],progress[43:29]};
      4:value={8'd0,bad_state_seen,ctrl_edge_seen,pll_unlock_seen,ctrl_reset_seen,
               low_wrap_seen,boot_exit_seen,start_seen,ever_watchdog[16]};
      5:value={7'd0,key1,pll_reset,reset,ctrl_reset_sync,ctrl_rst_n,
               reader_r1_msb,status_word[14],status_word[15]};
      6:value=status_word;
      default:value=16'hff00;
    endcase
endmodule
'''
p.write_text(new, encoding="utf-8", newline="\n")
guard = json.loads((PREVIOUS / "doc/output/SOURCE_GUARD.json").read_text(encoding="utf-8"))
guard["experiment"] = "A4: A3 functional RTL unchanged; watchdog bit history and reset-event observations only"
guard["a4_reverse_to_a3"] = {relative: [[old, new]]}
guard["a3_reverse_to_a2"][relative].append([old, new])
for row in guard["source_files"]:
    row["after_sha256"] = hashlib.sha256((OUT / "project/src" / row["path"]).read_bytes()).hexdigest()
    row["changed"] = row["before_sha256"] != row["after_sha256"]
(OUT / "doc/output/SOURCE_GUARD.json").write_text(json.dumps(guard, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(OUT / "doc/output/SOURCE_DIFF.patch").write_text("".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True), fromfile="A3/" + relative, tofile="A4/" + relative)), encoding="utf-8")
p = OUT / "scripts/validate_probe_sources.py"
text = p.read_text(encoding="utf-8")
needle = "previous=BASE/'experiments/board_0x46_A2_work/project/src'"
addition = '''a3_index=json.loads((BASE/'doc/output/BOARD_PROBE_A3_EVIDENCE_INDEX.json').read_text(encoding='utf-8'))
for row in a3_index['files']:
    assert sha(BASE/row['path'])==row['sha256'],'原A3封存变化: '+row['path']
for relative,changes in guard['a4_reverse_to_a3'].items():
    restored=(PROBE/'project/src'/relative).read_text(encoding='utf-8')
    for old,new in reversed(changes):
        assert restored.count(new)==1
        restored=restored.replace(new,old)
    assert restored==(BASE/'experiments/board_0x46_A3_work/project/src'/relative).read_text(encoding='utf-8')
'''
assert text.count(needle) == 1
text = text.replace(needle, addition + needle)
needle = "(PROBE/'doc/output/SOURCE_VALIDATION.json').write_text"
text = text.replace(needle, "result.update(a4_vs_a3_changed_files=1,a4_vs_a3_functional_change='NONE; temporary read-only observer only',original_a3_sealed_files_checked=len(a3_index['files']))\n" + needle)
p.write_text(text, encoding="utf-8", newline="\n")
print(OUT)
