"""F7C片上逻辑分析：F7功能源码加MARK_DEBUG观测标记，批处理插入ChipWatcher。"""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
OLD = ROOT / 'experiments/full_observe_F7'
WORK = ROOT / 'experiments/full_cw_F7C'
assert not WORK.exists(), '拒绝覆盖已有实验'
for folder in ('project/src', 'project/assets', 'scripts', 'tb/integration_lint', 'sim/integration_lint'):
    shutil.copytree(OLD / folder, WORK / folder)
(WORK / 'doc/output').mkdir(parents=True)
shutil.copy2(OLD / 'doc/output/ROUND2_SDC_EXPECTED.json', WORK / 'doc/output/ROUND2_SDC_EXPECTED.json')
shutil.copy2(OLD / 'sim/run_round2_lint.sh', WORK / 'sim/run_round2_lint.sh')
MARK = '(* MARK_DEBUG="TRUE" *) '


def patch(rel, pairs):
    path = WORK / 'project/src' / rel
    text = path.read_text(encoding='utf-8')
    for before, after in pairs:
        assert text.count(before) == 1, (rel, before)
        text = text.replace(before, after)
    path.write_text(text, encoding='utf-8')


# 观测点全部位于BASE50控制域，单个ChipWatcher实例即可覆盖。
patch('vendor/fdi_loader/fdi_sdram_cmd_engine.v', [
    ('    reg  [4:0]  state;\n', f'    {MARK}reg  [4:0]  state;\n'),
    ('    reg  [14:0] cnt;', f'    {MARK}reg  [14:0] cnt;'),
    ('    output reg         init_done,', f'    {MARK}output reg         init_done,'),
])
patch('rtl/fdi_label_store.v', [
    (' reg [3:0] state;\n', f' {MARK}reg [3:0] state;\n'),
    (' reg mem_busy;', f' {MARK}reg mem_busy;'),
])
patch('rtl/fdi_label_stream.v', [('    reg [3:0] state;\n', f'    {MARK}reg [3:0] state;\n')])
patch('rtl/v9_m6_hdmi.v', [
    ('    reg [3:0] loader_release;', f'    {MARK}reg [3:0] loader_release;'),
    ('    wire label_ready,rd_req_valid,rd_req_ready,rd_beat_valid,rd_done;',
     f'    wire label_ready,rd_beat_valid,rd_done;\n    {MARK}wire rd_req_valid,rd_req_ready;'),
    ('    wire [20:0] rd_req_addr,rd_beat_addr;', f'    {MARK}wire [20:0] rd_req_addr;\n    wire [20:0] rd_beat_addr;'),
])
patch('rtl/v9_udp_m6_master_top.v', [
    ('    reg [1:0] ctrl_reset_sync;', f'    {MARK}reg [1:0] ctrl_reset_sync;'),
    ('    wire reset;', f'    {MARK}wire reset;'),
    ("0:label_debug_value=16'd5476;", "0:label_debug_value=16'd5478;"),
])
patch('rtl/fdi_label_store.v', [(' output wire label_ready,output reg [7:0] error_code,',
                                  f' output wire label_ready,{MARK}output reg [7:0] error_code,')])

allowed = {'rtl/v9_udp_m6_master_top.v', 'rtl/v9_m6_hdmi.v', 'rtl/fdi_label_store.v',
           'rtl/fdi_label_stream.v', 'vendor/fdi_loader/fdi_sdram_cmd_engine.v'}
for original in (OLD / 'project/src').rglob('*'):
    if original.is_file() and original.relative_to(OLD / 'project/src').as_posix() not in allowed:
        assert original.read_bytes() == (WORK / 'project/src' / original.relative_to(OLD / 'project/src')).read_bytes()
guard = dict(source_files=[dict(path=p.relative_to(WORK / 'project/src').as_posix(),
                              after_sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                          for p in (WORK / 'project/src').rglob('*') if p.is_file()])
(WORK / 'doc/output/SOURCE_GUARD.json').write_text(json.dumps(guard, indent=2) + '\n', encoding='utf-8')

prepare = WORK / 'scripts/prepare_round2.cjs'
text = prepare.read_text(encoding='utf-8')
allowed_js = '"rtl/fdi_label_store.v", "rtl/v9_m6_hdmi.v",'
assert text.count(allowed_js) == 1
text = text.replace(allowed_js, allowed_js + ' "rtl/fdi_label_stream.v",')
for before, after in [
    ("'FULL_OBSERVE_F7'", "'FULL_CW_F7C'"),
    # 官方流程在RTL优化与布局前各调用一次insert_debugger。
    (" const rtlOpt=commands.indexOf('optimize_rtl');",
     " if(commands.indexOf('optimize_rtl')<0)throw Error('Missing RTL optimization command');\n"
     " commands.splice(commands.indexOf('optimize_rtl'),0,'insert_debugger');\n"
     " const rtlOpt=commands.indexOf('optimize_rtl');"),
    ("  commands.push(mode==='place'&&Number(placeSeed)===-1?'place -eco'",
     "  if(mode==='place')commands.push('insert_debugger');\n  commands.push(mode==='place'&&Number(placeSeed)===-1?'place -eco'"),
    ("else if(mode==='bit')commands.push('update_timing -mode final',`bitgen -bit ${root}/eth_udp_m6_master_top.bit`);",
     "else if(mode==='bit')commands.push('update_timing -mode final',`bitgen -bit ${root}/eth_udp_m6_master_top.bit`,"
     "`if {[catch {setup_debugger ${root} -bit ${root}/eth_udp_m6_master_top.bit} fdi_cw]} {puts \"FDI_CW_SETUP_ERROR: $fdi_cw\"} else {puts FDI_CW_SETUP_DONE}`);"),
]:
    assert text.count(before) == 1, before
    text = text.replace(before, after)
prepare.write_text(text, encoding='utf-8')
sources = WORK / 'sim/integration_lint/sources.f'
text = sources.read_text(encoding='utf-8').replace('/experiments/full_observe_F7/', '/experiments/full_cw_F7C/')
assert '/experiments/full_observe_F7/' not in text
sources.write_text(text, encoding='utf-8', newline='\n')
print(WORK)
