"""以封存M1R为基座创建TF1诊断副本，不修改已验模块或旧交付物。"""
import hashlib
import json
import shutil
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OLD = ROOT / 'experiments/sdram_selftest_M1R'
WORK = ROOT / 'experiments/tf_selftest_TF1'
A4 = ROOT / 'experiments/board_0x46_A4_work'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
assert not WORK.exists(), '禁止覆盖诊断目录'
for folder in ('project/src', 'scripts', 'tb'):
    shutil.copytree(OLD / folder, WORK / folder)
(WORK / 'sim').mkdir()
(WORK / 'doc/output').mkdir(parents=True)
for name in ('ROUND2_SDC_EXPECTED.json', 'M1_CONSTANT_SCOPE_PROOF.json'):
    shutil.copy2(OLD / 'doc/output' / name, WORK / 'doc/output' / name)
drivers = ['fdi_crc7_calc.v', 'fdi_mx_byte_engine.v', 'fdi_sd_cmd_transactor.v',
           'fdi_sd_init_sequence.v', 'fdi_sd_spi_byte_engine.v', 'fdi_sd_spi_sector_reader.v']
rows = []
for p in (WORK / 'project/src').rglob('*.v'):
    src = OLD / 'project/src' / p.relative_to(WORK / 'project/src')
    assert sha(p) == sha(src)
    if p.name != 'fdi_sdram_selftest_top.v':
        rows.append(dict(source=src.as_posix(), path=p.relative_to(WORK).as_posix(), sha256=sha(src)))
for name in drivers:
    src = A4 / 'project/src/vendor/fdi_loader' / name
    dest = WORK / 'project/src/vendor/fdi_loader' / name
    shutil.copy2(src, dest)
    rows.append(dict(source=src.as_posix(), path=dest.relative_to(WORK).as_posix(), sha256=sha(src)))
for name in ('sd_spi_card_model.sv',):
    shutil.copy2(ROOT / 'tb/controlled_loader' / name, WORK / 'tb' / name)
sector = (ROOT / 'project/assets/PCB.BMP').read_bytes()[:512]
assert len(sector) == 512 and sector[:2] == b'BM'
crc = zlib.crc32(sector)
(WORK / 'tb/first_sector.memh').write_text(''.join(f'{b:02x}\n' for b in sector), encoding='ascii')
(WORK / 'tb/controlled_image.memh').write_text('@00002000\n' + ''.join(
    f'{int.from_bytes(sector[i:i+4], "big"):08x}\n' for i in range(0, 512, 4)), encoding='ascii')
(WORK / 'doc/output/FIRST_SECTOR_GOLDEN.json').write_text(json.dumps(dict(
    lba=64, bytes=512, crc32=f'{crc:08X}', source=(ROOT / 'project/assets/PCB.BMP').as_posix(),
    source_sha256=sha(ROOT / 'project/assets/PCB.BMP'), sector_sha256=hashlib.sha256(sector).hexdigest(),
    first_sector_only=True, full_file_crc32='47E2A01D', rgb565_crc32='A1E4D4E1'), indent=2) + '\n')
(WORK / 'doc/output/REFERENCE_ASSETS.json').write_text(json.dumps(dict(
    copied=rows, diagnostic_only=True, spi_driver_changed=False, sdram_driver_changed=False,
    spi_clock='clk_50 independent BASE domain', miso_explicit_delay_buffers=0), indent=2) + '\n')
adc = WORK / 'project/src/constraints/eth_m6_master.adc'
pins = []
for line in (A4 / 'project/src/constraints/eth_m6_master.adc').read_text(encoding='utf-8').splitlines():
    if line.startswith('set_pin_assignment {sd_'):
        pins.append(line)
assert len(pins) == 4
adc.write_text(adc.read_text(encoding='utf-8') + '\n' + '\n'.join(pins) + '\n', encoding='utf-8')
sdc = WORK / 'project/src/constraints/eth_m6_master.sdc'
sdc.write_text(sdc.read_text(encoding='utf-8') + '''
# TF1基准50MHz域；沿用已有TF输入/输出设计预算，不豁免MISO数据路径。
set_input_delay -clock [get_clocks {clk_50}] -max 10.0 [get_ports {sd_miso}]
set_input_delay -clock [get_clocks {clk_50}] -min 0.0 [get_ports {sd_miso}]
set_output_delay -clock [get_clocks {clk_50}] -max 2.0 [get_ports {sd_dclk sd_mosi sd_ncs}]
set_output_delay -clock [get_clocks {clk_50}] -min 0.0 [get_ports {sd_dclk sd_mosi sd_ncs}]
''', encoding='utf-8')
expected = WORK / 'doc/output/ROUND2_SDC_EXPECTED.json'
data = json.loads(expected.read_text())
data['sdc_sha256'] = sha(sdc)
expected.write_text(json.dumps(data, indent=2) + '\n')
print(json.dumps(dict(work=WORK.as_posix(), first_sector_crc32=f'{crc:08X}', spi_driver_copies=len(drivers))))
