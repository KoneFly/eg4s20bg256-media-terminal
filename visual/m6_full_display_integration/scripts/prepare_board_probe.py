"""生成独立A0观测实验；不改已归档R2、驱动、卡契约或保护上游。"""
from pathlib import Path
import difflib
import hashlib
import json
import shutil

TASK = Path(__file__).resolve().parent.parent
OUT = TASK / 'experiments/board_0x46_A0_work'
if OUT.exists():
    raise SystemExit(f'Refuse overwrite: {OUT}')
OUT.mkdir(parents=True)
shutil.copytree(TASK/'project', OUT/'project', ignore=shutil.ignore_patterns('tests', 'obj_dir'))
shutil.copytree(TASK/'tb/controlled_loader', OUT/'tb/controlled_loader')
shutil.copytree(TASK/'sim/integration_lint', OUT/'sim/integration_lint',
                ignore=shutil.ignore_patterns('*.log', 'obj_dir'))
(OUT/'scripts').mkdir()
(OUT/'doc/output').mkdir(parents=True)
shutil.copy2(TASK/'doc/output/ROUND2_SDC_EXPECTED.json', OUT/'doc/output/ROUND2_SDC_EXPECTED.json')
for name in ('prepare_td.cjs', 'prepare_round2.cjs', 'read_round2.cjs', 'run_round2.ps1',
             'remap_physical_sdc.py', 'audit_round2_cdc.py', 'audit_round2_rom.cjs'):
    shutil.copy2(TASK/'scripts'/name, OUT/'scripts'/name)

def update(relative, old, new):
    p = OUT/relative
    text = p.read_text(encoding='utf-8')
    if text.count(old) != 1:
        raise RuntimeError(f'Expected one match: {relative} {old[:60]}')
    p.write_text(text.replace(old, new), encoding='utf-8', newline='\n')

STORE='project/src/rtl/fdi_label_store.v'
update(STORE, 'output wire rd_done\n', 'output wire rd_done,output reg [111:0] debug_snapshot\n')
start=(OUT/STORE).read_text(encoding='utf-8').index(' // MISO恒等缓冲')
end=(OUT/STORE).read_text(encoding='utf-8').index(' reg init_start', start)
text=(OUT/STORE).read_text(encoding='utf-8')
(OUT/STORE).write_text(text[:start]+' // A0单点实验：PAD直达原采样端，不加入缓冲或新拍。\n'+text[end:], encoding='utf-8', newline='\n')
update(STORE, '.spi_miso(miso_hold[4])', '.spi_miso(sd_miso)')
update(STORE, '.sd_miso(miso_hold[4])', '.sd_miso(sd_miso)')
update(STORE, ' task fail;\n', ''' // 临时只读观测：ERROR边沿锁存前一拍，此后冻结；KEY1复位清除。
 // 层次引用不改已验驱动端口、状态转移、SPI采样或SDRAM时序。
 reg [5:0] debug_sticky;
 wire [5:0] debug_events={eng_resp,u_init.u_cmd_xactor.byte_done,
                         u_init.cmd_timeout,u_init.cmd_done,init_error,init_done};
 wire [111:0] debug_live={
  unused_read_r1,unused_init_r1,
  (debug_sticky|debug_events),init_code,u_mem.state,write_index[17:16],
  write_index[15:0],
  eng_resp,sector_valid,sector_busy,init_done,init_error,u_init.cmd_timeout,u_init.cmd_done,
  u_init.u_cmd_xactor.u_byte_engine.state,u_init.u_cmd_xactor.state,bytes_seen[19:16],
  bytes_seen[15:0],
  u_init.u_cmd_xactor.byte_busy,u_init.cmd_busy,unused_init_busy,eng_ready,write_pending,sector_number,
  init_ready,eng_init,mem_busy,u_reader.state,u_init.state,state};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin debug_snapshot<=0;debug_sticky<=0;end
  else if(state!=ERROR)begin
   debug_snapshot<=debug_live;debug_sticky<=debug_sticky|debug_events;
  end
 end
 task fail;
''')
update('project/src/rtl/v9_m6_hdmi.v', 'output wire sd_dclk,sd_mosi,sd_ncs,output wire [7:0] label_fault_code,',
       'output wire sd_dclk,sd_mosi,sd_ncs,output wire [7:0] label_fault_code,\n    output wire [111:0] label_debug_snapshot,')
update('project/src/rtl/v9_m6_hdmi.v', '.rd_done(rd_done));', '.rd_done(rd_done),.debug_snapshot(label_debug_snapshot));')
TOP='project/src/rtl/v9_udp_m6_master_top.v'
update(TOP, 'wire [7:0] label_fault_code;', 'wire [7:0] label_fault_code;\n    wire [111:0] label_debug_snapshot;')
update(TOP, '.label_fault_code(label_fault_code),', '.label_fault_code(label_fault_code),\n        .label_debug_snapshot(label_debug_snapshot),')
update(TOP, '    // SW1改为ready诊断bank选择，调速固定正常档，切页不改变发送行为。\n', '''    // A0：SW0=1临时观测bank；切页只读，不改变任何加载握手。
    reg [15:0] label_debug_value;
    always @(*)case(sw[3:1])
      0:label_debug_value=16'd5460;
      1:label_debug_value=label_debug_snapshot[15:0];
      2:label_debug_value=label_debug_snapshot[31:16];
      3:label_debug_value=label_debug_snapshot[47:32];
      4:label_debug_value=label_debug_snapshot[63:48];
      5:label_debug_value=label_debug_snapshot[79:64];
      6:label_debug_value=label_debug_snapshot[95:80];
      default:label_debug_value=label_debug_snapshot[111:96];
    endcase
''')
update(TOP, '                               (label_fault_code!=0) ? 16\'d60000+{8\'d0,label_fault_code} :\n                               sw[0] ? ready_value : !key2_sync[1] ? diag_value : display_diagnostic;',
       "                               sw[0] ? label_debug_value :\n                               (label_fault_code!=0) ? 16'd60000+{8'd0,label_fault_code} :\n                               !key2_sync[1] ? diag_value : display_diagnostic;")
update(TOP, "reset ? 2'd3 : sw[0] ? 2'd2 :", "reset ? 2'd3 : sw[0] ? 2'd1 :")

# 工具路径绑定原基座，冻结检查绑定已出位R2源，仅允许上述三文件变化。
update('scripts/prepare_td.cjs', "const project=path.resolve(task,'../../..');",
       'const project='+json.dumps(TASK.parents[2].as_posix(), ensure_ascii=False)+';')
update('scripts/prepare_round2.cjs', "const frozen=path.join(task,'td_run/synth1g'),old=",
       'const frozen='+json.dumps((TASK/'td_run/bit2_final').as_posix(), ensure_ascii=False)+',old=')
update('scripts/prepare_round2.cjs', "const allowed=new Set(['rtl/fdi_label_store.v','vendor/fdi_loader/fdi_fat32_file_streamer.v','vendor/fdi_loader/fdi_fat32_volume_scanner.v']);",
       "const allowed=new Set(['rtl/fdi_label_store.v','rtl/v9_m6_hdmi.v','rtl/v9_udp_m6_master_top.v']);")
update('scripts/prepare_round2.cjs', 'manifest.mode=mode;manifest.round=2;manifest.frozen_round1_checks=checked.length;',
       "manifest.mode=mode;manifest.experiment='BOARD_0x46_A0';manifest.frozen_round2_checks=checked.length;")
for name in ('run_round2_loader.sh', 'run_round2_lint.sh'):
    text=(TASK/'sim'/name).read_text(encoding='utf-8').replace('/tmp/m6_fdi_r2_loader','/tmp/m6_fdi_a0_loader')
    (OUT/'sim'/name).write_text(text, encoding='utf-8', newline='\n')
def wsl(p):
    return '/mnt/'+p.drive[0].lower()+p.as_posix()[2:]
sources=OUT/'sim/integration_lint/sources.f'
sources.write_text(sources.read_text(encoding='utf-8').replace(wsl(TASK),wsl(OUT)), encoding='utf-8', newline='\n')
TB='tb/controlled_loader/tb_controlled_loader.sv'
update(TB, ' wire [7:0] error_code;', ' wire [7:0] error_code;\n wire [111:0] debug_snapshot;\n reg [111:0] saved_debug;')
update(TB, '   $display("RAW_FAULT_PASS', '''   saved_debug=debug_snapshot;
   if(saved_debug[3:0]==dut.ERROR)$fatal(1,"DEBUG_LOST_PRE_ERROR");
   repeat(20)@(negedge clk);
   if(debug_snapshot!==saved_debug)$fatal(1,"DEBUG_NOT_FROZEN");
   $display("DEBUG_FAULT_SNAPSHOT %h",debug_snapshot);
   $display("RAW_FAULT_PASS''')

# 源差异与每个未变文件的身份登记；不把仿真当作硬件证据。
rows=[]
diff=[]
for p in sorted((OUT/'project/src').rglob('*')):
    if not p.is_file(): continue
    rel=p.relative_to(OUT/'project/src').as_posix()
    old=TASK/'project/src'/rel
    before=hashlib.sha256(old.read_bytes()).hexdigest()
    after=hashlib.sha256(p.read_bytes()).hexdigest()
    rows.append(dict(path=rel,before_sha256=before,after_sha256=after,changed=before!=after))
    if before!=after:
        diff.extend(difflib.unified_diff(old.read_text(encoding='utf-8').splitlines(True),p.read_text(encoding='utf-8').splitlines(True),
                                      fromfile='R2/'+rel,tofile='A0/'+rel))
assert [r['path'] for r in rows if r['changed']]==[
    'rtl/fdi_label_store.v','rtl/v9_m6_hdmi.v','rtl/v9_udp_m6_master_top.v']
(OUT/'doc/output/SOURCE_DIFF.patch').write_text(''.join(diff),encoding='utf-8',newline='\n')
(OUT/'doc/output/SOURCE_GUARD.json').write_text(json.dumps({
    'experiment':'A0: four MISO LUT buffers removed, read-only pre-error snapshot',
    'hardware_status':'PENDING_TRUE_CARD','source_files':rows},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(OUT)
