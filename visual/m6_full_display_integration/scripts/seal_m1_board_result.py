"""封存M1真板读数与已复现的诊断缺陷；不覆盖旧发布索引。"""
import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
prior=ROOT/'doc/output/M1_SDRAM_SELFTEST_EVIDENCE_INDEX_20261006.json'
index=json.loads(prior.read_text(encoding='utf-8'))
for r in index['files']:
 p=ROOT/r['path'];assert p.stat().st_size==r['bytes'] and sha(p)==r['sha256']
record=ROOT/'doc/output/M1_BOARD_RESULT_20261006.json'
data=dict(date_local='2026-10-06',bit_sha256=index['bit_sha256'],
 raw_user_messages=['d0 5466 d1 255 d2 43528 d3 0 d4 4 d5 1 d6 0 d7 65280',
 'p1 16640 p2 00128 p3 65535 p4 16639，彩条正常'],
 d=dict(d0=5466,d1=255,d2=43528,d3=0,d4=4,d5=1,d6=0,d7=65280),
 p=dict(p1=16640,p2=128,p3=65535,p4=16639),color_bars='USER_CONFIRMED_NORMAL',
 decode=dict(code=8,bist_state=5,engine_state=10,address='040000',
              first_pass_completed=True,refresh_count_saturated=True),
 status='FAIL_DIAGNOSTIC_FALSE_ALARM_CONFIRMED_BY_BOUNDARY_REPRO',
 interpretation='已完成128写及16640正确读字，首通过后因自检刷新计数饱和而误报；不据此判SDRAM损坏或完整FDI通过。',
 reproduction='experiments/sdram_selftest_M1R/sim/saturation_old/result.log',
 duration_seconds=None,ten_minute_stability_confirmed=False,full_FDI_acceptance=False)
def save(p,obj):
 s=json.dumps(obj,ensure_ascii=False,indent=2)+'\n'
 if p.exists():assert p.read_text(encoding='utf-8')==s
 else:p.write_text(s,encoding='utf-8')
assert 'OLD_M1_SATURATION_REPRO flags=255 code=43528 address=040000 refreshes=65535' in (ROOT/data['reproduction']).read_text()
save(record,data)
save(ROOT/'doc/output/M1_BOARD_EVIDENCE_20261006.json',dict(status=data['status'],
 prior_index_sha256=sha(prior),verified_prior_entries=len(index['files']),
 files=[dict(path=p.relative_to(ROOT).as_posix(),bytes=p.stat().st_size,sha256=sha(p)) for p in [record,Path(__file__).resolve()]]))
print(json.dumps(dict(status=data['status'],verified_prior_entries=len(index['files']))))
