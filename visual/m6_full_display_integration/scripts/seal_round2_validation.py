"""冻结语义、最新加载测试、接口lint和卡工具结果的身份封存。"""
from pathlib import Path
import hashlib
import importlib.util
import json
import re

TASK = Path(__file__).resolve().parent.parent

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def read_json(p):
    return json.loads(p.read_text(encoding='utf-8-sig'))

old = TASK/'td_run/synth1g'
allowed = {'rtl/fdi_label_store.v', 'vendor/fdi_loader/fdi_fat32_file_streamer.v',
           'vendor/fdi_loader/fdi_fat32_volume_scanner.v'}
items = read_json(old/'SOURCE_MANIFEST.json')['compiled_files'] + [
    'vendor/w2/pcb_dynamic_roms_w2.vh', 'vendor/fdi_stream/fdi_row_span_rom.vh',
    'constraints/eth_m6_master.adc']
frozen = []
for rel in items:
    if rel in allowed:
        continue
    current = TASK/'project/src'/rel
    assert sha(current) == sha(old/'src'/rel), f'Frozen source drift: {rel}'
    frozen.append(dict(path=rel, sha256=sha(current), status='BYTE_IDENTICAL'))
assert len(frozen) == 61

sim = TASK/'sim/round2_loader'
prod = {p.name: p for p in (TASK/'project/src').rglob('*') if p.is_file()}
tb = {p.name: p for p in (TASK/'tb/controlled_loader').glob('*.sv')}
compiled = []
for line in (sim/'compiled_sources.sha256').read_text().splitlines():
    digest, name = line.split(None, 1)
    p = tb.get(name) or prod.get(name)
    assert p and sha(p) == digest, f'Test identity mismatch: {name}'
    compiled.append(dict(path=p.relative_to(TASK).as_posix(), sha256=digest))

names = ['normal_full_stream', 'file_CRC32_fault', 'BMP_header_fault',
         'SDRAM_label_CRC32_fault', 'wrong_raw_location', 'first_sector_CRC16_fault',
         'no_card_timeout', 'slow_data_token_full_stream', 'last_sector_CRC16_fault',
         'runtime_unaligned_address', 'runtime_out_of_range']
cases = []
for n, name in enumerate(names):
    p = sim/f'scenario{n}.log'
    text = p.read_text()
    assert re.search(rf'RAW_(LOADER|FAULT)_PASS scenario={n}\b', text)
    assert not re.search(r'%Error|Assertion failed|FAIL', text)
    if n in (0, 7):
        assert 'RAW_STREAM_PASS pixels=307200 SPIreads=1801' in text
    cases.append(dict(scenario=n, name=name, status='PASS',
                      log=p.relative_to(TASK).as_posix(), sha256=sha(p),
                      result_lines=[s for s in text.splitlines() if '_PASS' in s]))

logs = [TASK/'sim/round2_lint/w2_strict.log', sim/'strict_lint.log']
for p in logs:
    assert not re.search(r'%Warning|%Error', p.read_text())
app = TASK/'sim/round2_lint/application_top.log'
assert '%Error' not in app.read_text()
warnings = re.findall(r'^%Warning-([^:]+)', app.read_text(), re.M)
assert len(warnings) == 342
fixture = read_json(sim/'FIXTURE.json')
card = read_json(TASK/'sim/round2_card/TOOL_VALIDATION.json')
assert card['status'] == 'PASS' and len(card['checks']) == 8
assert read_json(TASK/'sim/w2_display_result.json')['simulation_status'] == 'PASS'
spec = importlib.util.spec_from_file_location('controlled_card', TASK/'scripts/make_controlled_card.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
real_image = TASK/'sim/round2_card/label_pcm_short_real.img'
real_metadata = read_json(real_image.with_suffix('.img.json'))
real_result = tool.verify(real_image)
assert real_result['status'] == 'PASS_IMAGE'
assert real_result['image_sha256'] == real_metadata['image_sha256']
real_inputs = []
for expected, recovered in zip(real_metadata['pcm_files'], real_result['pcm_files'], strict=True):
    source = Path(expected['source'])
    assert sha(source) == expected['sha256'] == recovered['sha256']
    assert expected['bytes'] == recovered['bytes']
    real_inputs.append(dict(source=str(source), sha256=sha(source),
                            bytes=source.stat().st_size, status='READ_ONLY_IDENTITY_PASS'))
assert len(real_inputs) == 4
real_result.update(synthetic_PCM_only=False, readonly_inputs=real_inputs,
                   durations_seconds=[p['bytes']/96000 for p in real_result['pcm_files']])
(TASK/'sim/round2_card/REAL_PCM_IMAGE_VALIDATION.json').write_text(
    json.dumps(real_result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
result = dict(
    status='PASS_FUNCTIONAL_WITH_OPEN_INTERFACE_WARNINGS',
    frozen_round1_sources=frozen, frozen_round1_count=len(frozen),
    production_changes_from_round1=['rtl/fdi_label_store.v',
                                   'constraints/eth_m6_master.sdc'],
    removed_production_files=sorted(allowed-{'rtl/fdi_label_store.v'}),
    compiled_loader_inputs=compiled, loader_cases=cases, fixture=fixture,
    loader_test_configuration=dict(STARTUP_CYCLES=32, controller_hz=50000000,
        BOOT_TIMEOUT_CYCLES=60000000, note='Short startup test; production defaults unchanged'),
    loader_strict_lint=dict(status='PASS', warnings=0, errors=0,
        log_sha256=sha(sim/'strict_lint.log')),
    W2_strict_lint=dict(status='PASS', warnings=0, errors=0,
        log_sha256=sha(logs[0])),
    application_interface_lint=dict(status='PASS', warnings=len(warnings), errors=0,
        warning_status='OPEN', log_sha256=sha(app),
        scope='Original IP boundary stubs and public primitives; IP internals and physical delays excluded'),
    round1_W2_S2_evidence_reuse=dict(
        reason='61 frozen RTL/include/ADC items byte identical; label-facing formal interface unchanged',
        file='sim/w2_display_result.json',
        sha256=sha(TASK/'sim/w2_display_result.json'),
        write_batches=2404, writes=1567408, display_frames=2403,
        retiming_pixels=738201600, JS_golden_frames=40, JS_golden_pixels=12288000,
        max_W2_update_cycles=18276, rerun_this_round=False),
    controlled_card_tool=dict(status='PASS', checks=8, synthetic_PCM_only=True,
        hardware_card_written=False,
        result_sha256=sha(TASK/'sim/round2_card/TOOL_VALIDATION.json')),
    real_short_PCM_image=dict(status='PASS_IMAGE', hardware_card_written=False,
        image='sim/round2_card/label_pcm_short_real.img', sha256=real_result['image_sha256'],
        PCM_source='052 read-only short files', result_sha256=sha(TASK/'sim/round2_card/REAL_PCM_IMAGE_VALIDATION.json')),
    physical_timing_proof='Separate native TD final-route reports; Verilator identity BUF does not model delay',
    hardware_board_acceptance='NOT_STARTED')
(TASK/'doc/output/ROUND2_VALIDATION.json').write_text(
    json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
print(json.dumps(dict(status=result['status'], frozen=len(frozen),
                     loader_cases=len(cases), application_warnings=len(warnings))))
