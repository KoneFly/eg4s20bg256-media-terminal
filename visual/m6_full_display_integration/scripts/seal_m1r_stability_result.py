"""追加用户确认的M1R长稳与复位结果，不改写既有封存记录。"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
prior = ROOT / 'doc/output/M1R_EVIDENCE_INDEX_20261006.json'
index = json.loads(prior.read_text(encoding='utf-8'))
for row in index['files']:
    path = ROOT / row['path']
    assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256'], str(path)
initial = ROOT / 'doc/output/M1R_INITIAL_BOARD_RESULT_20261006.json'
question = '请保持M1R连续运行≥10分钟，确认彩条仍正常、SW0=1时d1=00127/d2=00000、SW0=0页100时P4=16639；记录后再按复位键约1秒，放开等2秒，确认彩条及d0～d7恢复本次正常值。请反馈长稳和复位复现结果。'
record = ROOT / 'doc/output/M1R_STABILITY_BOARD_RESULT_20261006.json'
data = dict(date_local='2026-10-06', bit_sha256=index['bit_sha256'],
            raw_question=question, raw_user_message='≥10分钟均正常，复位后正常复现',
            status='USER_CONFIRMED_TEN_MINUTE_STABILITY_AND_RESET_REPEATABILITY',
            minimum_duration_seconds=600, color_bars_normal=True,
            d1=127, d2=0, p4=16639, reset_repeatability_confirmed=True,
            interpretation='用户确认问题中长稳、彩条、指定读数和复位复现全部正常；SDRAM分层自检通过。',
            scope='M1R_SDRAM_LAYER_ONLY', full_FDI_acceptance=False,
            next_stage='FROZEN_TF_INIT_AND_LBA64_FIRST_SECTOR_SELFTEST')

def save(path, value):
    content = json.dumps(value, ensure_ascii=False, indent=2) + '\n'
    if path.exists():
        assert path.read_text(encoding='utf-8') == content, '禁止覆盖不同板测记录'
    else:
        path.write_text(content, encoding='utf-8')

save(record, data)
files = [record, Path(__file__).resolve(), initial]
save(ROOT / 'doc/output/M1R_STABILITY_BOARD_EVIDENCE_20261006.json',
     dict(status=data['status'], prior_index_sha256=sha(prior),
          verified_prior_entries=len(index['files']), bit_sha256=index['bit_sha256'],
          files=[dict(path=p.relative_to(ROOT).as_posix(), bytes=p.stat().st_size,
                      sha256=sha(p)) for p in files]))
print(json.dumps(dict(status=data['status'], verified_prior_entries=len(index['files']))))
