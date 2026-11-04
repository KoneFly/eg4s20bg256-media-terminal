"""追加M1R首轮用户读数，长期及复位项目仍待报告。"""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
prior=ROOT/'doc/output/M1R_EVIDENCE_INDEX_20261006.json'
index=json.loads(prior.read_text(encoding='utf-8'))
for row in index['files']:
    path=ROOT/row['path']
    assert path.stat().st_size==row['bytes'] and sha(path)==row['sha256'],str(path)

record=ROOT/'doc/output/M1R_INITIAL_BOARD_RESULT_20261006.json'
observation=dict(
    date_local='2026-10-06',bit_sha256=index['bit_sha256'],
    raw_user_message='1. **d0=05467**\n2. **d1=00127、d2=00000，d3 255，d4 24 d5 23130 d6 23130 d7 65280**',
    d=dict(d0=5467,d1=127,d2=0,d3=255,d4=24,d5=23130,d6=23130,d7=65280),
    status='USER_CONFIRMED_ALL_INITIAL_D_READINGS_MATCH',
    interpretation='按冻结RTL状态语义，首轮两组写读与刷新保持已完成，当前快照无错误；不代签持续巡检或复位复现。',
    color_bars_current_run_confirmed=False,p_pages_current_run=None,
    duration_seconds=None,ten_minute_stability_confirmed=False,
    key1_repeatability_confirmed=False,full_FDI_acceptance=False,
    pending=['>=10分钟彩条与d1/d2稳定','当前P4=16639','KEY1复位后正常值复现'],
    next_stage_after_board_checks='FROZEN_TF_INIT_AND_CONTROLLED_LBA_HEADER_READ')

def save(path,data):
    text=json.dumps(data,ensure_ascii=False,indent=2)+'\n'
    if path.exists():
        assert path.read_text(encoding='utf-8')==text,'禁止覆盖不同板测记录'
    else:
        path.write_text(text,encoding='utf-8')

save(record,observation)
files=[record,Path(__file__).resolve()]
save(ROOT/'doc/output/M1R_INITIAL_BOARD_EVIDENCE_20261006.json',dict(
    status=observation['status'],prior_index_sha256=sha(prior),
    verified_prior_entries=len(index['files']),bit_sha256=index['bit_sha256'],
    files=[dict(path=p.relative_to(ROOT).as_posix(),bytes=p.stat().st_size,sha256=sha(p)) for p in files]))
print(json.dumps(dict(status=observation['status'],verified_prior_entries=len(index['files']))))
