"""追加TF1真实初读结果；长稳与复位项目单独待验。"""
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

record = ROOT / 'doc/output/TF1_INITIAL_BOARD_RESULT_20261006.json'
observation = dict(
    date_local='2026-10-06', bit_sha256=index['bit_sha256'],
    raw_user_message='`05468、00127、00000、00512、00112、24356、62544、65280`  ；SW0=0：**P1持续增加，P4=16639、P5=127、P6=0**，彩条正常。',
    status='USER_CONFIRMED_INITIAL_TF_SECTOR_REPEAT_READ_PASS',
    d=dict(d0=5468, d1=127, d2=0, d3=512, d4=112, d5=24356, d6=62544, d7=65280),
    p=dict(p1_increasing=True, p2=None, p3=None, p4=16639, p5=127, p6=0),
    color_bars_normal=True, sector_lba=64, sector_bytes=512, sector_crc32='F4505F24',
    interpretation='按本位冻结RTL，TF初始化、原reader CRC16、首扇区CRC32及重复读取通过；S1/M1R健康。',
    duration_seconds=None, ten_minute_stability_confirmed=False,
    reset_repeatability_confirmed=False, full_file_crc_verified=False,
    full_FDI_acceptance=False,
    original_A4_root_cause='UNRESOLVED: BASE域/启动依赖和MISO缓冲同时区别，不能单点归因',
    pending=['>=10分钟真卡复读、彩条与S1/M1R健康', '复位后正常读数及复读恢复'],
    next_stage_after_board_checks='CONTROLLED_FULL_LABEL_LOAD_AND_FILE_SDRAM_DOUBLE_CRC')

def save(path, data):
    content = json.dumps(data, ensure_ascii=False, indent=2) + '\n'
    if path.exists():
        assert path.read_text(encoding='utf-8') == content, '禁止覆盖不同板测记录'
    else:
        path.write_text(content, encoding='utf-8')

save(record, observation)
files = [record, Path(__file__).resolve()]
save(ROOT / 'doc/output/TF1_INITIAL_BOARD_EVIDENCE_20261006.json', dict(
    status=observation['status'], prior_index_sha256=sha(prior),
    verified_prior_entries=len(index['files']), bit_sha256=index['bit_sha256'],
    files=[dict(path=p.relative_to(ROOT).as_posix(), bytes=p.stat().st_size, sha256=sha(p)) for p in files]))
print(json.dumps(dict(status=observation['status'], verified_prior_entries=len(index['files']))))
