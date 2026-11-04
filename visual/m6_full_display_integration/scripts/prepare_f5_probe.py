"""F5单点实验：BOOT启动阈值保持有效，正常启动拍数不变。"""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
OLD = ROOT / 'experiments/full_reset_F4'
WORK = ROOT / 'experiments/full_start_F5'
assert not WORK.exists(), '拒绝覆盖已有实验'
for folder in ('project/src', 'project/assets', 'scripts', 'tb/integration_lint', 'sim/integration_lint'):
    shutil.copytree(OLD / folder, WORK / folder)
(WORK / 'doc/output').mkdir(parents=True)
shutil.copy2(OLD / 'doc/output/ROUND2_SDC_EXPECTED.json', WORK / 'doc/output/ROUND2_SDC_EXPECTED.json')
shutil.copy2(OLD / 'sim/run_round2_lint.sh', WORK / 'sim/run_round2_lint.sh')
top = WORK / 'project/src/rtl/v9_udp_m6_master_top.v'
text = top.read_text(encoding='utf-8')
assert text.count("0:label_debug_value=16'd5473;") == 1
top.write_text(text.replace("0:label_debug_value=16'd5473;", "0:label_debug_value=16'd5474;"), encoding='utf-8')
store = WORK / 'project/src/rtl/fdi_label_store.v'
text = store.read_text(encoding='utf-8')
before = '    BOOT:if(watchdog==START_LIMIT)begin init_start<=1;state<=INIT;end'
after = '''    // 达到启动阈值后持续有效；正常计数仍在原定500000拍启动。
    BOOT:if(watchdog>=START_LIMIT)begin init_start<=1;state<=INIT;end'''
assert text.count(before) == 1
store.write_text(text.replace(before, after), encoding='utf-8')
allowed = {'rtl/v9_udp_m6_master_top.v', 'rtl/fdi_label_store.v'}
for original in (OLD / 'project/src').rglob('*'):
    if original.is_file() and original.relative_to(OLD / 'project/src').as_posix() not in allowed:
        assert original.read_bytes() == (WORK / 'project/src' / original.relative_to(OLD / 'project/src')).read_bytes()
guard = dict(source_files=[dict(path=p.relative_to(WORK / 'project/src').as_posix(),
                              after_sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                          for p in (WORK / 'project/src').rglob('*') if p.is_file()])
(WORK / 'doc/output/SOURCE_GUARD.json').write_text(json.dumps(guard, indent=2) + '\n')
prepare = WORK / 'scripts/prepare_round2.cjs'
prepare.write_text(prepare.read_text(encoding='utf-8').replace("'FULL_RESET_F4'", "'FULL_START_F5'"), encoding='utf-8')
sources = WORK / 'sim/integration_lint/sources.f'
source_text = sources.read_text(encoding='utf-8').replace('/experiments/full_reset_F4/', '/experiments/full_start_F5/')
assert '/experiments/full_reset_F4/' not in source_text
sources.write_text(source_text, encoding='utf-8', newline='\n')
shutil.copy2(OLD / 'sim/run_f4_reset.sh', WORK / 'sim/run_f5_start.sh')
run_script = WORK / 'sim/run_f5_start.sh'
run_script.write_text(run_script.read_text(encoding='utf-8').replace('f4_reset', 'f5_start'), encoding='utf-8', newline='\n')
shutil.copy2(OLD / 'tb/tb_f4_reset.sv', WORK / 'tb/tb_f5_start.sv')
bench = WORK / 'tb/tb_f5_start.sv'
text = bench.read_text(encoding='utf-8').replace('tb_f4_reset', 'tb_f5_start').replace('F4_RESET_PASS', 'F5_RESET_PASS')
text = text.replace('initial begin run_boot();run_boot();$finish;end', '''initial begin
  run_boot();run_boot();
  // 略过精确阈值后仍须启动；模拟观测到的启动点未推进情况。
  @(negedge clk_50);key1=0;repeat(20)@(posedge clk_50);@(negedge clk_50);key1=1;
  repeat(10)@(posedge clk_50);@(negedge clk_50);
  dut.u_display.u_label_store.watchdog=29'd500005;
  @(posedge clk_50);@(negedge clk_50);
  assert(dut.u_display.u_label_store.state==1 && dut.u_display.u_label_store.init_start)
   else $fatal(1,"越过启动阈值后仍停在BOOT");
  repeat(5)@(posedge clk_50);@(negedge clk_50);
  assert(dut.u_display.u_label_store.u_init.init_busy)
   else $fatal(1,"初始化器未接受迟到的启动请求");
  $display("F5_LATE_START_PASS init_busy=1");$finish;
 end''')
bench.write_text(text, encoding='utf-8', newline='\n')
print(WORK)
