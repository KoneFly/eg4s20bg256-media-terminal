"""逐条约束查询、实际例外端点与冻结SDC身份交叉核验。"""
from pathlib import Path
import hashlib
import json
import re
import sys

TASK = Path(__file__).resolve().parent.parent
run = Path(sys.argv[1]).resolve()
step = sys.argv[2]
physical = (run/'ACTIVE_SDC_EXPECTED.json').exists()
expected = json.loads(((run/'ACTIVE_SDC_EXPECTED.json') if physical else (TASK/'doc/output/ROUND2_SDC_EXPECTED.json')).read_text())
manifest = json.loads((run/'SOURCE_MANIFEST.json').read_text())
log = (run/'console.log').read_text(errors='replace')
false_set, mcp_set = set(expected['false_data_endpoints']), set(expected['mcp_data_endpoints'])
queries = {p: value.strip().strip('{}') for p, value in re.findall(r'^R2_PIN (\S+) *(.*)$', log, re.M)}
errors, rules = [], []
for p in sorted(false_set | mcp_set):
    if queries.get(p) != p:
        errors.append(f'exact_pin_query:{p}:{queries.get(p)}')
for bit in (() if physical else (2,3,6)):
    p = f'u_display/u_scan/ctrl_error_meta_reg[{bit}].d'
    if queries.get(p) != '':
        errors.append(f'constant_meta_not_folded:{p}')
ignored = (run/f'{step}_ignored.timing').read_text(errors='replace')
exception = (run/f'{step}_exception.timing').read_text(errors='replace')
# SFP报告包括原基座key和网口边界；只核对本轮新增首级D端规则。
actual_false = set()
for block in re.split(r'^Constr\s*:', ignored, flags=re.M)[1:]:
    first = block.splitlines()[0].strip()
    match = re.fullmatch(r'set_false_path -to \[get_pins \{([^}]+)\}\]', first)
    if not match:
        match = re.fullmatch(r'set_false_path -to \[get_clocks \{[^}]+\}\] -through \[get_pins \{([^}]+)\}\]',first)
    if not match:
        continue
    target = match[1]
    ends = set(re.findall(r'^End Point\s*:\s*(\S+?)\(', block, re.M))
    if target not in false_set or ends != {target}:
        errors.append(f'false_scope:{target}:actual={len(ends)} extra={len(ends-{target})}')
    actual_false.update(ends)
    rules.append(dict(constraint=first, actual_endpoints=sorted(ends)))
if actual_false != false_set:
    errors.append(f'false_endpoint_set_missing:{sorted(false_set-actual_false)}')
actual_mcp = set(re.findall(r'^End Point\s*:\s*(\S+)', exception, re.M))
if actual_mcp != mcp_set:
    errors.append(f'mcp_scope_missing={len(mcp_set-actual_mcp)} extra={sorted(actual_mcp-mcp_set)}')
summary = exception.split('MCP/SMD Details')[0]
summary_targets = re.findall(r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+set_multicycle_path (4|3) -(setup|hold) -end -from \[get_clocks \{([^}]+)\}\] -to \[get_pins \{([^}]+)\}\]', summary, re.M)
if len(summary_targets) != 2048:
    errors.append(f'mcp_summary_count:{len(summary_targets)}')
for total, dominated, shadowed, ignored_count, cycles, kind, clock, target in summary_targets:
    if (total, dominated, shadowed, ignored_count) != ('1','1','0','0') or clock != expected['mcp_source_clock'] or target not in mcp_set:
        errors.append(f'mcp_summary_bad:{target}')
sdc = (run/'production.sdc').read_bytes()
sdc_sha = hashlib.sha256(sdc).hexdigest()
if sdc_sha != expected['sdc_sha256'] or sdc_sha != manifest.get('active_sdc_sha256',manifest['sdc_sha256']):
    errors.append('SDC_identity')
netlist = (run/f'{step}_netlist.v').read_text(errors='replace')
if not re.search(r'\b(?:AL_MAP_SEQ|EG_PHY_MSLICE)\b', netlist):
    errors.append('missing_real_gate_netlist')
result = dict(status='PASS_PRECISE_SCOPE' if not errors else 'OPEN', errors=errors,
              confidence=json.loads((run/'RESULT.json').read_text())['confidence'],
              false_data_endpoints=len(actual_false), mcp_data_endpoints=len(actual_mcp),
              exact_queries=len(false_set|mcp_set), optimized_meta_bits=[2,3,6],
              accidental_pixel_shift_mcp_endpoints=0 if actual_mcp==mcp_set else None,
              source_D_CE_alias_exemptions=0 if actual_false==false_set else None,
              hold_reference='destination CTRL clock, explicit -end MC3', sdc_sha256=sdc_sha,
              manifest_sha256=hashlib.sha256((run/'SOURCE_MANIFEST.json').read_bytes()).hexdigest(),
              rules=rules, mcp_actual_endpoints=sorted(actual_mcp))
(run/'CDC_AUDIT.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ('rules','mcp_actual_endpoints')}))
if errors:
    raise SystemExit(1)
