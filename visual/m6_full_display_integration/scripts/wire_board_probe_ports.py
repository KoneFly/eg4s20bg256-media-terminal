"""TD不支持层次读网：仅给实验副本加只读端口，恢复逆变换须逐字节等于R2。"""
from pathlib import Path
import difflib
import hashlib
import json
import shutil

TASK=Path(__file__).resolve().parent.parent
OUT=TASK/'experiments/board_0x46_A0_work'
edits={}
def edit(rel,old,new):
    p=OUT/'project/src'/rel
    text=p.read_text(encoding='utf-8')
    if text.count(old)!=1: raise ValueError(f'{rel}: match {old[:70]}')
    p.write_text(text.replace(old,new),encoding='utf-8',newline='\n')
    edits.setdefault(rel,[]).append((old,new))

prefix='vendor/fdi_loader/'
edit(prefix+'fdi_sd_spi_byte_engine.v', 'output reg                  done\n',
     'output reg                  done,\n    output wire [1:0]          debug_state\n')
edit(prefix+'fdi_sd_spi_byte_engine.v', '    reg [1:0] state;',
     '    reg [1:0] state;\n    // Temporary read-only board probe.\n    assign debug_state=state;')
edit(prefix+'fdi_sd_cmd_transactor.v', '    output reg                       cmd_timeout,',
     '    output reg                       cmd_timeout,\n    output wire [6:0]                 debug_status,')
edit(prefix+'fdi_sd_cmd_transactor.v', '    reg [2:0]                 state;',
     '    reg [2:0]                 state;\n    wire [1:0] debug_byte_state;\n    // Temporary read-only board probe.\n    assign debug_status={byte_done,byte_busy,debug_byte_state,state};')
# 定位原done端口，不触及引擎请求与采样。
p=OUT/'project/src'/prefix/'fdi_sd_cmd_transactor.v'
text=p.read_text(encoding='utf-8')
import re
line=re.search(r'^\s*\.done\s*\(byte_done\)[^\n]*',text,re.M).group()
edit(prefix+'fdi_sd_cmd_transactor.v',line,line.rstrip().rstrip(',')+',\n        .debug_state(debug_byte_state)')
edit(prefix+'fdi_sd_init_sequence.v', '    output wire [7:0]                init_resp_r1,',
     '    output wire [7:0]                init_resp_r1,\n    output wire [13:0]               debug_status,')
edit(prefix+'fdi_sd_init_sequence.v', '    reg [3:0]           state;',
     '    reg [3:0]           state;\n    wire [6:0] debug_cmd_status;\n    // Temporary read-only board probe.\n    assign debug_status={debug_cmd_status[6:5],cmd_busy,cmd_done,cmd_timeout,debug_cmd_status[4:0],state};')
edit(prefix+'fdi_sd_init_sequence.v', '        .cmd_timeout (cmd_timeout),',
     '        .cmd_timeout (cmd_timeout),\n        .debug_status(debug_cmd_status),')
edit(prefix+'fdi_sd_spi_sector_reader.v', '    output wire        sector_busy,',
     '    output wire        sector_busy,\n    output wire [4:0]  debug_state,')
edit(prefix+'fdi_sd_spi_sector_reader.v', '    reg [4:0] state;',
     '    reg [4:0] state;\n    // Temporary read-only board probe.\n    assign debug_state=state;')
edit(prefix+'fdi_sdram_cmd_engine.v', '    output reg         init_done,',
     '    output wire [4:0] debug_state,  // 临时只读上板观测\n    output reg         init_done,')
edit(prefix+'fdi_sdram_cmd_engine.v', '    reg  [4:0]  state;',
     '    reg  [4:0]  state;\n    // 临时只读上板观测，不改变命令、采样或握手。\n    assign debug_state=state;')

rel='rtl/fdi_label_store.v'
edit(rel,' wire init_done,init_error,card_sdhc;',
     ' wire init_done,init_error,card_sdhc;\n wire [13:0] debug_init;\n wire [4:0] debug_reader,debug_mem;')
edit(rel,'.init_error(init_error),','.debug_status(debug_init),.init_error(init_error),')
edit(rel,'.sector_busy(sector_busy),','.debug_state(debug_reader),.sector_busy(sector_busy),')
edit(rel,'.clk(clk),.rst_n(rst_n),.init_done(eng_init),',
     '.clk(clk),.rst_n(rst_n),.debug_state(debug_mem),.init_done(eng_init),')
for old,new in [('u_init.u_cmd_xactor.byte_done','debug_init[13]'),
                ('u_init.u_cmd_xactor.byte_busy','debug_init[12]'),
                ('u_init.u_cmd_xactor.u_byte_engine.state','debug_init[8:7]'),
                ('u_init.u_cmd_xactor.state','debug_init[6:4]'),
                ('u_init.cmd_timeout','debug_init[9]'),
                ('u_init.cmd_done','debug_init[10]'),
                ('u_init.cmd_busy','debug_init[11]'),
                ('u_mem.state','debug_mem'),('u_reader.state','debug_reader'),('u_init.state','debug_init[3:0]')]:
    p=OUT/'project/src'/rel
    text=p.read_text(encoding='utf-8')
    assert old in text
    p.write_text(text.replace(old,new),encoding='utf-8',newline='\n')
edit(rel,' // 层次引用不改已验驱动端口、状态转移、SPI采样或SDRAM时序。',
     ' // 驱动只加显式只读端口，不改状态转移、SPI采样或SDRAM时序。')

script=OUT/'scripts/prepare_round2.cjs'
text=script.read_text(encoding='utf-8')
old="const allowed=new Set(['rtl/fdi_label_store.v','rtl/v9_m6_hdmi.v','rtl/v9_udp_m6_master_top.v']);"
allowed=['rtl/fdi_label_store.v','rtl/v9_m6_hdmi.v','rtl/v9_udp_m6_master_top.v']+list(edits.keys())[:-1]
assert old in text
script.write_text(text.replace(old,'const allowed=new Set('+json.dumps(allowed)+');'),encoding='utf-8',newline='\n')
shutil.copytree(TASK/'tb/integration_lint',OUT/'tb/integration_lint')

port_guards=[]
for rel,pairs in edits.items():
    if not rel.startswith(prefix):continue
    p=OUT/'project/src'/rel
    reverse=p.read_text(encoding='utf-8')
    for old,new in reversed(pairs):
        assert reverse.count(new)==1
        reverse=reverse.replace(new,old)
    original=(TASK/'project/src'/rel).read_text(encoding='utf-8')
    assert reverse==original,rel
    port_guards.append(dict(path=rel,functional_body_unchanged=True,reversible_additions=pairs))
rows=[];diff=[]
for p in sorted((OUT/'project/src').rglob('*')):
    if not p.is_file():continue
    rel=p.relative_to(OUT/'project/src').as_posix();old=TASK/'project/src'/rel
    before=hashlib.sha256(old.read_bytes()).hexdigest();after=hashlib.sha256(p.read_bytes()).hexdigest()
    rows.append(dict(path=rel,before_sha256=before,after_sha256=after,changed=before!=after))
    if before!=after:
        diff.extend(difflib.unified_diff(old.read_text(encoding='utf-8').splitlines(True),p.read_text(encoding='utf-8').splitlines(True),
                                       fromfile='R2/'+rel,tofile='A0/'+rel))
(OUT/'doc/output/SOURCE_DIFF.patch').write_text(''.join(diff),encoding='utf-8',newline='\n')
(OUT/'doc/output/SOURCE_GUARD.json').write_text(json.dumps({
 'experiment':'A0: no MISO buffers, pre-error snapshot through read-only ports',
 'hardware_status':'PENDING_TRUE_CARD','driver_port_reverse_guards':port_guards,'source_files':rows},
 ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('PASS: 5 driver files only reversible read-only ports, original functional bodies identical')
