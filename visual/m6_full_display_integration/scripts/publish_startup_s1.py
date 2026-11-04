"""S1独立诊断位签核归档；不代签硬件验收，不修改上游索引。"""
import hashlib
import json
from pathlib import Path
import runpy
import shutil

ROOT=Path(__file__).resolve().parents[1]
WORK=ROOT/'experiments/startup_selftest_S1'
RUN=WORK/'td_run/bit_s1_final'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
read=lambda p:json.loads(p.read_text(encoding='utf-8-sig'))
runpy.run_path(str(ROOT/'scripts/seal_a4_confirmed_readback.py'))
result=read(RUN/'RESULT.json')
assert result['status']=='PASS_STAGE' and result['timing_pass'] and result['measured']['mslices']<4900
assert read(RUN/'CDC_AUDIT.json')['status']=='PASS_PRECISE_SCOPE'
assert read(RUN/'BIST_NATIVE_AUDIT.json')['status']=='PASS_NATIVE_BIST_AND_HARDMACRO_SOURCES'
manifest=read(RUN/'SOURCE_MANIFEST.json')
for row in manifest['files']:
 assert sha(WORK/'project/src'/row['path'])==row['sha256']==sha(RUN/'src'/row['path'])
assets=read(WORK/'doc/output/REFERENCE_ASSETS.json')['copied']
for row in assets:
 assert sha(Path(row['source']))==row['sha256']==sha(WORK/'project/src'/row['path'])
source_map={'fdi_startup_bist.v':'project/src/rtl/fdi_startup_bist.v','fdi_fixed_video.v':'project/src/rtl/fdi_fixed_video.v',
            'axis_pixel_adapter.v':'project/src/vendor/display020/axis_pixel_adapter.v','tb_selftest.sv':'tb/tb_selftest.sv'}
for line in (WORK/'sim/core_final/SOURCE.sha256').read_text().splitlines():
 digest,name=line.split(None,1);name=name.strip()
 assert sha(WORK/source_map[name])==digest==sha(WORK/'sim/core_final/src'/name)
assert '--assert' in (WORK/'sim/run_selftest.sh').read_text()
assert 'S1_SELFTEST_PASS' in (WORK/'sim/core_final/result.log').read_text()
validation=read(WORK/'doc/output/SOFTWARE_VALIDATION.json')
assert validation['assertions_enabled'] and all(row['errors']==0 for row in validation['lint'])
bit=RUN/'fdi_selftest_top.bit'
assert sha(bit)==result['bit']['sha256']
target=ROOT/'deliverables'/f"M6_FDI_S1_20261006_{sha(bit)[:8].upper()}.bit"
if target.exists():assert sha(target)==sha(bit)
else:shutil.copy2(bit,target)
reference=ROOT.parents[2]/'iccoder_workspace/tasks/task_052_ethernet_pcm_link/td_run/v9_display_20261004_final2/eth_udp_m6_master_top.bit'
observation=dict(date_local='2026-10-06',raw_user_message='画面正常，p1是1，一直正常，那就切换思路，之前思路改了好几次一直不行该换了',
 reference_bit_sha256=sha(reference),hardware_status='USER_REPORTED_NORMAL_PICTURE_AND_P1_1',duration_seconds=None,
 independently_witnessed=False,full_FDI_acceptance=False,authorized_next_step='ISOLATED_MINIMAL_SELFTEST')
outputs={ROOT/'doc/output/S1_REFERENCE_BOARD_RESULT_20261006.json':observation,
 ROOT/'deliverables/S1_SELFTEST_MANIFEST.json':dict(status='DIAGNOSTIC_ONLY_PENDING_BOARD',bit_path=target.relative_to(ROOT).as_posix(),
   bit_sha256=sha(target),bit_bytes=target.stat().st_size,measured=result['measured'],sta=result['sta'],
   source_manifest_sha256=sha(RUN/'SOURCE_MANIFEST.json'),cdc_audit_sha256=sha(RUN/'CDC_AUDIT.json'),native_bist_audit_sha256=sha(RUN/'BIST_NATIVE_AUDIT.json'),
   software_validation_sha256=sha(WORK/'doc/output/SOFTWARE_VALIDATION.json'),subboard='7175ECC3_UNCHANGED',tf_layout='UNCHANGED_NOT_USED_IN_S1')}
for path,data in outputs.items():
 serialized=json.dumps(data,ensure_ascii=False,indent=2)+'\n'
 if path.exists():assert path.read_text(encoding='utf-8')==serialized,'禁止覆盖不同交付证据'
 else:path.write_text(serialized,encoding='utf-8')
paths=[p for p in WORK.rglob('*') if p.is_file() and '__pycache__' not in p.parts]
paths += [target,*outputs,ROOT/'scripts/prepare_startup_selftest.py',Path(__file__).resolve(),ROOT/'doc/output/S1_SELFTEST_REPORT_20261006.md']
index=dict(status='SEALED_DIAGNOSTIC_SOFTWARE_AND_NATIVE_TD',hardware_status='PENDING_S1_BOARD_TEST',
 bit_sha256=sha(target),previous_confirmed_evidence_sha256=sha(ROOT/'doc/output/A4_PROBE_BOARD_CONFIRMED_EVIDENCE_20261006.json'),
 files=[dict(path=p.relative_to(ROOT).as_posix(),bytes=p.stat().st_size,sha256=sha(p)) for p in sorted(set(paths))])
path=ROOT/'doc/output/S1_SELFTEST_EVIDENCE_INDEX_20261006.json'
serialized=json.dumps(index,ensure_ascii=False,indent=2)+'\n'
if path.exists():assert path.read_text(encoding='utf-8')==serialized,'禁止覆盖不同证据索引'
else:path.write_text(serialized,encoding='utf-8')
print(json.dumps(dict(status=index['status'],entries=len(index['files']),bit=target.as_posix(),sha256=sha(target)),ensure_ascii=False))
