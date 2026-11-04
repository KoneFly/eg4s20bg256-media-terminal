"""封存用户确认的TF1十分钟及复位复现结果。"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
prior = ROOT / 'doc/output/TF1_EVIDENCE_INDEX_20261006.json'
index = json.loads(prior.read_text(encoding='utf-8'))
for row in index['files']:
    p = ROOT / row['path']
    assert p.stat().st_size == row['bytes'] and sha(p) == row['sha256'], str(p)
record = ROOT / 'doc/output/TF1_STABILITY_BOARD_RESULT_20261006.json'
data = dict(date_local='2026-10-06', bit_sha256=index['bit_sha256'],
    raw_question='请保持 TF1 本次运行累计≥10分钟，确认彩条正常、P1仍增加、d1=127/d2=0、P4=16639/P5=127/P6=0；随后按复位键约1秒，放开等12秒，确认d0～d7恢复本次正常值且P1重新增加。请反馈长稳和复位复现结果。',
    raw_user_message='≥10分钟正常，复位后正常复现',
    status='USER_CONFIRMED_TF1_TEN_MINUTE_AND_RESET_PASS',
    minimum_duration_seconds=600, color_bars_normal=True, repeat_reads_increasing=True,
    d1=127, d2=0, p4=16639, p5=127, p6=0, reset_repeatability_confirmed=True,
    scope='TF_INITIALIZATION_AND_LBA64_SECTOR_REPEAT_READ',
    full_file_crc_verified=False, full_FDI_acceptance=False,
    next_stage='FULL_CONTROLLED_LABEL_LOAD_AND_FILE_SDRAM_DOUBLE_CRC')

def save(p, value):
    content = json.dumps(value, ensure_ascii=False, indent=2) + '\n'
    if p.exists():
        assert p.read_text(encoding='utf-8') == content, '禁止覆盖不同板测记录'
    else:
        p.write_text(content, encoding='utf-8')

save(record, data)
files = [record, Path(__file__).resolve(), ROOT / 'doc/output/TF1_INITIAL_BOARD_RESULT_20261006.json']
save(ROOT / 'doc/output/TF1_STABILITY_BOARD_EVIDENCE_20261006.json', dict(
    status=data['status'], prior_index_sha256=sha(prior), verified_prior_entries=len(index['files']),
    bit_sha256=index['bit_sha256'], files=[dict(path=p.relative_to(ROOT).as_posix(),
    bytes=p.stat().st_size, sha256=sha(p)) for p in files]))
print(json.dumps(dict(status=data['status'], verified_prior_entries=len(index['files']))))
