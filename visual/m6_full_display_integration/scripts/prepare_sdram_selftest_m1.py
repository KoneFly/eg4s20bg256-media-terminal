"""创建M1独立SDRAM诊断副本，冻结S1时钟/视频及A4存储引擎。"""
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT=Path(__file__).resolve().parents[1]
OLD=ROOT/'experiments/startup_selftest_S1'
WORK=ROOT/'experiments/sdram_selftest_M1'
assert not WORK.exists() or (sys.argv[1:]==['--resume'] and not (WORK/'td_run').exists()), '禁止覆盖已有M1构建'
copied=[]
def copy(source, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    digest=hashlib.sha256(source.read_bytes()).hexdigest()
    if dest.exists():
        assert hashlib.sha256(dest.read_bytes()).hexdigest()==digest
    else:
        shutil.copy2(source,dest)
    assert hashlib.sha256(dest.read_bytes()).hexdigest()==digest
    copied.append(dict(source=source.as_posix(),path=dest.relative_to(WORK).as_posix(),sha256=digest))

for path in sorted((OLD/'project/src').rglob('*.v')):
    if path.name!='fdi_selftest_top.v':
        copy(path,WORK/'project/src'/path.relative_to(OLD/'project/src'))
copy(OLD/'project/src/constraints/eth_m6_master.adc',WORK/'project/src/constraints/eth_m6_master.adc')
for name in ('fdi_sdram_cmd_engine.v','fdi_sdram_refresh_timer.v'):
    copy(ROOT/'experiments/board_0x46_A4_work/project/src/vendor/fdi_loader'/name,
         WORK/'project/src/vendor/fdi_loader'/name)
copy(ROOT/'tb/controlled_loader/EG_PHY_SDRAM_2M_32.sv',WORK/'tb/EG_PHY_SDRAM_2M_32.sv')
for name in ('primitive_interfaces.v','boundary_stubs.sv'):
    copy(OLD/'tb/lint'/name,WORK/'tb/lint'/name)

top=(OLD/'project/src/rtl/fdi_selftest_top.v').read_text(encoding='utf-8')
top=top.replace('module fdi_selftest_top','module fdi_sdram_selftest_top')
start=top.index(' reg [15:0] value;')
end=top.index(' wire [15:0] scan_pins;',start)
top=top[:start]+''' // S1自检继续运行；M1结果在独立冻结总线上发布，彩条不受存储就绪门控。
 wire m1_toggle,m1_valid;wire [164:0] m1_source,m1_result;
 fdi_sdram_selftest u_sdram_test(.clk(ctrl_clk),.mem_clk(mem_clk),.key1(key1),.rst_n(ctrl_rst_n),
  .result_toggle(m1_toggle),.result_data(m1_source));
 fdi_m1_observer u_m1_observer(.clk(clk_50),.key1(key1),.source_toggle(m1_toggle),
  .source_data(m1_source),.captured_data(m1_result),.captured_valid(m1_valid));
 wire s1_healthy=captured_valid && !captured_mismatch && captured_flags==4'hf &&
                 captured_dut==29'd499999 && captured_reference==29'd499999;
 reg [15:0] value;
 always @(*)case(sw[3:1])
  0:value=16'd5466;
  1:value=sw[0]?m1_result[15:0]:(m1_valid?m1_result[116:101]:ctrl_cycles);
  2:value=sw[0]?m1_result[31:16]:(m1_valid?m1_result[132:117]:mem_cycles);
  3:value=sw[0]?m1_result[47:32]:(m1_valid?m1_result[148:133]:pixel_cycles);
  4:value=sw[0]?{11'd0,m1_result[52:48]}:(status | (s1_healthy?16'd0:16'h8000));
  5:value=sw[0]?m1_result[68:53]:m1_result[84:69];
  6:value=sw[0]?m1_result[100:85]:m1_result[164:149];
  default:value=16'hff00;
 endcase
''' +top[end:]
top=top.replace('assign led={captured_mismatch || ctrl_reset_seen || pll_unlock_seen,video_lock,captured_valid,ctrl_valid && !ctrl_stale};',
 'assign led={m1_result[7] || captured_mismatch || ctrl_reset_seen || pll_unlock_seen,video_lock,m1_valid,s1_healthy};')
(WORK/'project/src/rtl/fdi_sdram_selftest_top.v').write_text(top,encoding='utf-8')
for directory in ('scripts','sim','doc/output'):
    (WORK/directory).mkdir(parents=True,exist_ok=True)
for name in ('prepare_s1.py','run_s1.ps1','read_s1.py','remap_physical_sdc.py','audit_round2_cdc.py','audit_bist_native.py'):
    text=(OLD/'scripts'/name).read_text(encoding='utf-8')
    text=text.replace('fdi_selftest_top','fdi_sdram_selftest_top').replace('check_s1','check_m1')
    # S1脚本作为诊断框架，标记独立M1流水线；原始S1全封存不动。
    if name in ('prepare_s1.py','read_s1.py'):
        text=text.replace('S1_','M1_').replace('S1_ERROR','M1_ERROR')
    filename=Path(name).stem.replace('s1','m1')+Path(name).suffix
    (WORK/'scripts'/filename).write_text(text,encoding='utf-8')
runner=WORK/'scripts/run_m1.ps1'
text=runner.read_text(encoding='utf-8').replace('prepare_s1.py','prepare_m1.py').replace('read_s1.py','read_m1.py').replace('fdi_s1_','fdi_m1_')
runner.write_text(text,encoding='utf-8')
prep=WORK/'scripts/prepare_m1.py'
text=prep.read_text(encoding='utf-8')
text=text.replace('"u_video/video_meta_reg.d", "u_video/pll_meta_reg.d"]',
                  '"u_video/video_meta_reg.d", "u_video/pll_meta_reg.d", "u_m1_observer/toggle_meta_reg.d"]')
text=text.replace('"u_observer/captured_mismatch_reg.d"]',
                  '"u_observer/captured_mismatch_reg.d"] + [f"u_m1_observer/captured_data_reg[{bit}].d" for bit in range(165)]')
text=text.replace('    # 使用原生物理映射/', '    # 使用原生物理映射/')
begin=text.index('    # 使用原生物理映射/')
finish=text.index('\nif len(sys.argv)',begin)
text=text[:begin]+text[finish:]
prep.write_text(text,encoding='utf-8')
(WORK/'doc/output/REFERENCE_ASSETS.json').write_text(json.dumps(dict(copied=copied,
 diagnostic_only=True, spi_tf_w2_s2_not_instantiated=True, original_files_changed=0),ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(WORK)
