"""M1独立SDRAM诊断签核、位归档及证据封存；硬件结果保持待测。"""
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT=Path(__file__).resolve().parents[1]
WORK=ROOT/'experiments/sdram_selftest_M1'
RUN=WORK/'td_run/bit_m1_signed'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
read=lambda p:json.loads(p.read_text(encoding='utf-8-sig'))
def save(path,data):
    text=json.dumps(data,ensure_ascii=False,indent=2)+'\n'
    if path.exists():assert path.read_text(encoding='utf-8')==text,'禁止覆盖不同封存'
    else:path.write_text(text,encoding='utf-8')

for name in ('S1_SELFTEST_EVIDENCE_INDEX_20261006.json','S1_SELFTEST_BOARD_EVIDENCE_20261006.json'):
    index=read(ROOT/'doc/output'/name)
    for row in index['files']:
        p=ROOT/row['path'];assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
for row in read(WORK/'doc/output/REFERENCE_ASSETS.json')['copied']:
    assert sha(Path(row['source']))==row['sha256']==sha(WORK/row['path'])

result=read(RUN/'RESULT.json');native=read(RUN/'BIST_NATIVE_AUDIT.json');cdc=read(RUN/'CDC_AUDIT.json')
assert result['status']=='PASS_STAGE' and result['timing_pass'] and result['measured']['mslices']<4900
assert cdc['status']=='PASS_PRECISE_SCOPE' and cdc['errors']==[]
assert native['status']=='PASS_NATIVE_BIST_AND_HARDMACRO_SOURCES'
assert len(native['physical_m1_snapshot_registers'])==321 and len(native['physical_dq_capture'])==32
assert len(native['m1_constant_address_bits'])==9 and len(native['m1_snapshot_dynamic_register_pairs'])==156
manifest=read(RUN/'SOURCE_MANIFEST.json')
for row in manifest['files']:
    assert sha(WORK/'project/src'/row['path'])==row['sha256']==sha(RUN/'src'/row['path'])
assert len(manifest['compiled_files'])==14
route=WORK/'td_run/route_m1'
assert manifest['signoff_cdc_sha256']==sha(route/'CDC_AUDIT.json')
assert manifest['signoff_native_bist_sha256']==sha(route/'BIST_NATIVE_AUDIT.json')
assert cdc['sdc_sha256']==sha(RUN/'production.sdc')==sha(route/'physical.sdc')
native_log=(RUN/'console.log').read_text(errors='replace')
assert all(marker in native_log for marker in ('report_route_status -drc','No multi-drive.',
       'All clock nets do not utilize local routing resource.','No abnormal timing path.')), '原生DRC清洁标记缺失'

# 绑定断言实际编译输入；模型仅用于功能验证，HDMI加密内部不在仿真证明范围。
sources={p.name:p for p in (WORK/'project/src').rglob('*.v')}
sources.update({p.name:p for p in (WORK/'tb').rglob('*') if p.is_file()})
software=[]
for folder,marker in [('sdram_preserved','M1_SDRAM_PASS'),('pages','M1_TOP_PAGES_PASS')]:
    sim=WORK/'sim'/folder
    for line in (sim/'SOURCE.sha256').read_text().splitlines():
        digest,name=line.split(None,1);name=name.strip()
        assert sha(sources[name])==digest==sha(sim/'src'/name)
    logs=[sim/f'scenario_{n}.log' for n in range(11)] if folder=='sdram_preserved' else [sim/'result.log']
    for log in logs:assert marker in log.read_text() and '%Error' not in log.read_text()
    runner=WORK/'sim'/('run_sdram.sh' if folder=='sdram_preserved' else 'run_pages.sh')
    assert '--assert' in runner.read_text()
    software.append(dict(name=folder,source_sha256=sha(sim/'SOURCE.sha256'),runner_sha256=sha(runner),
                         assertions_enabled=True,results=[dict(path=p.relative_to(WORK).as_posix(),sha256=sha(p)) for p in logs]))
lint=[]
for log in sorted((WORK/'sim/lint').glob('*.log')):
    text=log.read_text();assert '%Error' not in text
    categories=re.findall(r'%Warning-([A-Z0-9_]+)',text)
    if log.name!='application.log':assert not categories
    lint.append(dict(path=log.relative_to(WORK).as_posix(),errors=0,warnings=len(categories),
        categories={c:categories.count(c) for c in sorted(set(categories))},sha256=sha(log)))
validation=WORK/'doc/output/SOFTWARE_VALIDATION.json'
save(validation,dict(status='PASS_ASSERTED_FUNCTION_AND_DEFAULT_STRICT_CORE',software=software,lint=lint,
    application_warnings_status='OPEN',clock_video_reference='S1资产逐字节复用；S1真实板测结果单独封存',
    scope_limits='SDRAM行为模型及顶层诊断mux验证；不替代真板存储延迟、PLL或加密HDMI内部功能。'))

bit=RUN/'fdi_sdram_selftest_top.bit';assert sha(bit)==result['bit']['sha256']
target=ROOT/'deliverables'/f'M6_FDI_M1_20261006_{sha(bit)[:8].upper()}.bit'
if target.exists():assert sha(target)==sha(bit)
else:shutil.copy2(bit,target)
delivery=ROOT/'deliverables/M1_SDRAM_SELFTEST_MANIFEST.json'
save(delivery,dict(status='DIAGNOSTIC_ONLY_PENDING_BOARD',hardware_status='PENDING_M1_BOARD_TEST',
 bit_path=target.relative_to(ROOT).as_posix(),bit_bytes=bit.stat().st_size,bit_sha256=sha(bit),
 version_decimal=5466,hdmi='HDMI-B',subboard='7175ECC3_UNCHANGED',tf_layout='UNCHANGED_NOT_USED_IN_M1',
 measured=result['measured'],sta=result['sta'],source_manifest_sha256=sha(RUN/'SOURCE_MANIFEST.json'),
 cdc_audit_sha256=sha(RUN/'CDC_AUDIT.json'),native_audit_sha256=sha(RUN/'BIST_NATIVE_AUDIT.json'),
 software_validation_sha256=sha(validation),s1_board_evidence_sha256=sha(ROOT/'doc/output/S1_SELFTEST_BOARD_EVIDENCE_20261006.json')))

process=WORK/'doc/output/PROCESS_RECORD.json'
save(process,dict(
    unsigned_probes=['synth_m1_probe','synth_m1','check_m1'],
    changes_before_final_source_freeze=['请求方刷新事件合并、写等待地址诊断、首错快照和捕获寄存器保留属性；未改冻结引擎',
        '门级buf证明地址bit9..17恒零，只撤销9项无动态源MC；其余219动态D端保持MC4/3'],
    preparation_issues=[
        '首次创建脚本将.ps1后缀误替为.pm1，修复后恢复创建；遗留草稿run_m1.pm1不参与执行',
        '页映射TB的表达式切片语法错误，改用整数位切片后实际顶层16页断言通过',
        'bit_m1_final首次准备因route_m1/physical.sdc尚未生成而退出，未启动TD；随后物理映射哈希与已加载SDC一致，bit_m1_signed成功'],
    timing_history={tag:read(WORK/'td_run'/tag/'RESULT.json') for tag in
        ('synth_m1_scoped','check_m1_final','place_m1','route_m1','bit_m1_signed')},
    final_rtl_modified_after_scoped_synthesis=False,automatic_programming_performed=False))

report=ROOT/'doc/output/M1_SDRAM_SELFTEST_REPORT_20261006.md'
assert report.is_file(),'先完成可复核板测指引'
paths=[p for p in WORK.rglob('*') if p.is_file() and '__pycache__' not in p.parts and 'obj_dir' not in p.parts]
paths += [target,delivery,report,Path(__file__).resolve(),ROOT/'scripts/prepare_sdram_selftest_m1.py',
          ROOT/'doc/brief/BOARD_DIAGNOSTIC_PROGRESS_M1_20261006.md']
save(ROOT/'doc/output/M1_SDRAM_SELFTEST_EVIDENCE_INDEX_20261006.json',dict(
 status='SEALED_DIAGNOSTIC_SOFTWARE_AND_NATIVE_TD',hardware_status='PENDING_M1_BOARD_TEST',bit_sha256=sha(bit),
 previous_s1_evidence_sha256=sha(ROOT/'doc/output/S1_SELFTEST_EVIDENCE_INDEX_20261006.json'),
 previous_s1_board_evidence_sha256=sha(ROOT/'doc/output/S1_SELFTEST_BOARD_EVIDENCE_20261006.json'),
 files=[dict(path=p.relative_to(ROOT).as_posix(),bytes=p.stat().st_size,sha256=sha(p)) for p in sorted(set(paths))]))
print(json.dumps(dict(bit=target.as_posix(),sha256=sha(bit),measured=result['measured'],sta=result['sta']),ensure_ascii=False))
