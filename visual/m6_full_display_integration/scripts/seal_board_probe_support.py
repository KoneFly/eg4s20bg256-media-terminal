"""补充归档A2边界、硬件待填记录与A0未通过门禁的过程证据。"""
from pathlib import Path
import hashlib
import json

BASE=Path(__file__).resolve().parent.parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
paths=[
 'doc/brief/BOARD_PROBE_SCOPE_20261005.md','doc/output/BOARD_PROBE_A2_BOARD_RECORD.md',
 'scripts/prepare_board_probe.py','scripts/wire_board_probe_ports.py','scripts/prepare_board_probe_a2.py',
 'scripts/seal_board_probe_support.py',
 'experiments/board_0x46_A0_work/doc/output/CONSTRAINT_REVISION.md',
 'experiments/board_0x46_A0_work/td_run/hold_a0_clock/RESULT.json',
 'experiments/board_0x46_A0_work/td_run/hold_a0_clock/SOURCE_MANIFEST.json',
 'experiments/board_0x46_A0_work/td_run/hold_a0_clock/route.timing',
 'experiments/board_0x46_A0_work/td_run/hold_a0_clock/route_netlist.v',
 'experiments/board_0x46_A0_work/td_run/hold_a0_clock/production.sdc',
 'experiments/board_0x46_A0_work/td_run/hold_a0_clock/CDC_AUDIT.json',
 'experiments/board_0x46_A0_work/td_run/hold_a0_clock/ROM_AUDIT.json']
entries=[dict(path=r,bytes=(BASE/r).stat().st_size,sha256=sha(BASE/r)) for r in paths]
result=dict(status='SEALED_SUPPORTING_EVIDENCE',hardware_status='PENDING_TRUE_CARD',
            primary_index_sha256=sha(BASE/'doc/output/BOARD_PROBE_A2_EVIDENCE_INDEX.json'),files=entries)
(BASE/'doc/output/BOARD_PROBE_A2_SUPPORTING_EVIDENCE.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
for index in ('BOARD_PROBE_A2_EVIDENCE_INDEX.json','ROUND2_EVIDENCE_INDEX.json'):
    data=json.loads((BASE/'doc/output'/index).read_text(encoding='utf-8'))
    for row in data['files']:assert sha(BASE/row['path'])==row['sha256'],row['path']
for row in entries:assert sha(BASE/row['path'])==row['sha256']
print('PASS: A2 319 artifacts + 14 supporting artifacts + original R2 400 artifacts; hardware PENDING')
