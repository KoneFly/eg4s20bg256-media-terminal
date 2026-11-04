"""追加S1用户板测记录；不覆盖软件签核或推定未报告的长稳结果。"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
prior = ROOT / 'doc/output/S1_SELFTEST_EVIDENCE_INDEX_20261006.json'
index = json.loads(prior.read_text(encoding='utf-8'))
for row in index['files']:
    p = ROOT / row['path']
    assert p.stat().st_size == row['bytes'] and sha(p) == row['sha256'], str(p)

observation = dict(
    date_local='2026-10-06', raw_user_messages=['可以正常显示彩条', '全部正确'],
    question_answered='SW0=1，每页等0.3秒，d1～d6符合预期，d0=05465、d7=65280',
    question_expected_values=dict(d0=5465, d1='32767 +/-2', d2='32767 +/-2',
        d3='65014 +/-2', d4=15, d5=16639, d6=41247, d7=65280),
    raw_individual_readings_provided=False,
    hardware_status='USER_CONFIRMED_S1_COLOR_BARS_AND_ALL_REQUESTED_READINGS',
    bit_sha256=index['bit_sha256'], independently_witnessed=False,
    duration_seconds=None, ten_minute_stability_confirmed=False,
    key1_repeatability_confirmed=False, full_FDI_acceptance=False,
    interpretation='本次独立诊断视频、相对时钟测量及冻结计数结果符合预期；不能证明完整工程已修复。',
    next_stage='ISOLATED_SDRAM_INIT_AND_BL8_READBACK_WITH_FROZEN_ENGINE')

def save(path, data):
    serialized = json.dumps(data, ensure_ascii=False, indent=2) + '\n'
    if path.exists():
        assert path.read_text(encoding='utf-8') == serialized, '禁止覆盖不同板测记录'
    else:
        path.write_text(serialized, encoding='utf-8')

record = ROOT / 'doc/output/S1_SELFTEST_BOARD_RESULT_20261006.json'
save(record, observation)
paths = [record, Path(__file__).resolve()]
save(ROOT / 'doc/output/S1_SELFTEST_BOARD_EVIDENCE_20261006.json', dict(
    status='SEALED_USER_REPORTED_S1_FUNCTIONAL_CHECK', prior_index_sha256=sha(prior),
    verified_prior_entries=len(index['files']), bit_sha256=index['bit_sha256'],
    files=[dict(path=p.relative_to(ROOT).as_posix(), bytes=p.stat().st_size, sha256=sha(p)) for p in paths]))
print(json.dumps(dict(status=observation['hardware_status'], verified_prior_entries=len(index['files']))))
