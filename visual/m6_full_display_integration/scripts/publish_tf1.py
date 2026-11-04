"""签核并封存TF1模型/原生TD/只读真卡诊断交付，不覆盖历史位。"""
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'experiments/tf_selftest_TF1'
RUN = WORK / 'td_run/bit_tf1'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
read = lambda p: json.loads(p.read_text(encoding='utf-8-sig'))

def save(path, value):
    content = json.dumps(value, ensure_ascii=False, indent=2) + '\n'
    if path.exists():
        assert path.read_text(encoding='utf-8') == content, '禁止覆盖不同封存文件'
    else:
        path.write_text(content, encoding='utf-8')

verified = {}
for name in ('M1R_EVIDENCE_INDEX_20261006.json', 'M1R_INITIAL_BOARD_EVIDENCE_20261006.json',
             'M1R_STABILITY_BOARD_EVIDENCE_20261006.json'):
    index = read(ROOT / 'doc/output' / name)
    for row in index['files']:
        path = ROOT / row['path']
        assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256'], str(path)
    verified[name] = len(index['files'])
protected = read(ROOT / 'doc/output/ROUND2_PREFLIGHT.json')['artifacts']
for row in protected:
    p = Path(row['path'])
    p = p if p.is_absolute() else ROOT / p
    content = p.read_bytes() if p.exists() else gzip.decompress(Path(str(p) + '.gz').read_bytes())
    assert len(content) == row['bytes'] and hashlib.sha256(content).hexdigest() == row['sha256']
for row in read(WORK / 'doc/output/REFERENCE_ASSETS.json')['copied']:
    assert sha(Path(row['source'])) == row['sha256'] == sha(WORK / row['path'])
result, cdc, native, tf = [read(RUN / name) for name in (
    'RESULT.json', 'CDC_AUDIT.json', 'BIST_NATIVE_AUDIT.json', 'TF_NATIVE_AUDIT.json')]
assert result['timing_pass'] and result['measured']['mslices'] < 4900 and result['measured']['dsp'] == 0
assert cdc['status'] == 'PASS_PRECISE_SCOPE' and not cdc['errors']
assert native['status'] == 'PASS_NATIVE_BIST_AND_HARDMACRO_SOURCES'
assert len(native['physical_m1_snapshot_registers']) == 321
assert tf['status'] == 'PASS_TF_BASE_REGISTERS_AND_IO' and len(tf['physical_tf_registers']) == 455
assert cdc['sdc_sha256'] == tf['sdc_sha256'] == sha(RUN / 'production.sdc')
assert tf['netlist_sha256'] == native['native_netlist_sha256'] == sha(RUN / 'route_netlist.v')
manifest = read(RUN / 'SOURCE_MANIFEST.json')
assert len(manifest['compiled_files']) == 21
for row in manifest['files']:
    assert sha(WORK / 'project/src' / row['path']) == row['sha256'] == sha(RUN / 'src' / row['path'])
route = WORK / 'td_run/route_tf1'
assert manifest['signoff_cdc_sha256'] == sha(route / 'CDC_AUDIT.json')
assert manifest['signoff_native_bist_sha256'] == sha(route / 'BIST_NATIVE_AUDIT.json')
assert all(s in (RUN / 'console.log').read_text(errors='replace') for s in (
    'No multi-drive.', 'All clock nets do not utilize local routing resource.', 'No abnormal timing path.'))
golden = read(WORK / 'doc/output/FIRST_SECTOR_GOLDEN.json')
assert sha(Path(golden['source'])) == golden['source_sha256']
sources = {p.name: p for p in (WORK / 'project/src').rglob('*.v')}
sources.update({p.name: p for p in (WORK / 'tb').rglob('*') if p.is_file()})
software = []
for folder, subdir, marker in [('tf', 'sources', 'TF1_PASS'), ('pages', 'src', 'TF1_TOP_PAGES_PASS')]:
    sim = WORK / 'sim' / folder
    for line in (sim / 'SOURCE.sha256').read_text(encoding='utf-8').splitlines():
        digest, name = line.split(None, 1)
        name = name.strip()
        p = sources[Path(name).name]
        assert sha(p) == digest == sha(sim / name if folder == 'tf' else sim / subdir / name)
    logs = sorted(sim.glob('case_*.log')) + [sim / 'default_nominal.log'] if folder == 'tf' else [sim / 'result.log']
    assert len(logs) == (9 if folder == 'tf' else 1)
    assert all(marker in p.read_text(encoding='utf-8') for p in logs)
    software.append(dict(name=folder, assertions_enabled=True, cases=len(logs),
                         source_sha256=sha(sim / 'SOURCE.sha256'),
                         logs=[dict(path=p.relative_to(WORK).as_posix(), sha256=sha(p)) for p in logs]))
assert all('--assert' in (WORK / 'sim' / name).read_text() for name in ('run_tf.sh', 'run_pages.sh'))
lint = []
for p in (WORK / 'sim/lint').glob('*.log'):
    content = p.read_text(encoding='utf-8')
    assert '%Error' not in content
    warnings = len(re.findall('%Warning-', content))
    if p.name != 'application.log':
        assert warnings == 0
    lint.append(dict(path=p.relative_to(WORK).as_posix(), errors=0, warnings=warnings, sha256=sha(p)))
assert len(lint) == 2
warnings = []
for tag in ('synth_tf1', 'check_m1_final', 'place_tf1', 'route_tf1', 'bit_tf1'):
    stage_result = read(WORK / 'td_run' / tag / 'RESULT.json')
    warnings.append(dict(stage=tag, **stage_result['warnings']))
save(WORK / 'doc/output/VALIDATION.json', dict(
    status='PASS_ASSERTED_TF_AND_PAGES_AND_NATIVE_TD', software=software, lint=lint,
    td_warnings=warnings, application_and_model_warnings='OPEN', prior_verified=verified,
    protected_artifacts_verified=len(protected), full_file_crc_not_tested=True,
    accelerated_fault_cases=True, default_parameters_nominal_and_reset_tested=True,
    hardware_status='PENDING_TF1_BOARD_TEST'))
bit = RUN / 'fdi_sdram_selftest_top.bit'
assert sha(bit) == result['bit']['sha256']
target = ROOT / 'deliverables' / f'M6_FDI_TF1_20261006_{sha(bit)[:8].upper()}.bit'
if target.exists():
    assert sha(target) == sha(bit)
else:
    shutil.copy2(bit, target)
delivery = ROOT / 'deliverables/TF1_MANIFEST.json'
save(delivery, dict(status='DIAGNOSTIC_PENDING_BOARD', bit_path=target.relative_to(ROOT).as_posix(),
                   bit_sha256=sha(bit), bit_bytes=bit.stat().st_size, version_decimal=5468,
                   measured=result['measured'], sta=result['sta'],
                   source_manifest_sha256=sha(RUN / 'SOURCE_MANIFEST.json'), cdc_sha256=sha(RUN / 'CDC_AUDIT.json'),
                   native_sha256=sha(RUN / 'BIST_NATIVE_AUDIT.json'), tf_native_sha256=sha(RUN / 'TF_NATIVE_AUDIT.json'),
                   parent_board_evidence_sha256=sha(ROOT / 'doc/output/M1R_STABILITY_BOARD_EVIDENCE_20261006.json')))
report = ROOT / 'doc/output/TF1_REPORT_20261006.md'
text = f'''# TF1：独立基准时钟TF首扇区自检（2026-10-06）

状态：M1R已完成用户确认的≥10分钟及复位复现；TF1软件、布局布线、精确CDC范围及原生连接通过，新位待真卡板测。完整M6-FDI仍未验收。

主板位：**{target.name}**（{bit.stat().st_size}B）；SHA256：`{sha(bit)}`。副板保持7175ECC3，HDMI-B，使用既有受控TF卡，不改写卡内容。BURN_INDEX由主人/规格方登记，本工具不烧录。

变化仅在新增TF请求/诊断层和顶层页选择：原SPI六模块逐字复制，初始化2048轮/分频63、扇区读分频1保持，初始化390.625kHz、读取25MHz；在独立clk_50 BASE域、KEY1复位下运行，不依赖原CTRL复位/加载启动。MISO零人工EG_LOGIC_BUF；原S1、M1R控制器、SDRAM命令/刷新引擎及50MHz/180°时钟逐字不变。既有数字页改显示TF状态，P4/P5/P6继续暴露S1/M1R健康。遵循KISS，未添加文件系统或新的SPI实现；冻结驱动以接口复用。

每次CMD17只读LBA64，要求512字节索引连续、原读引擎CRC16无错、整扇区CRC32=F4505F24。成功后每约250ms复读，P1成功次数递增、饱和65535；CRC32逐位计算共享异或网络。成功读数只在完整通过时更新，首次失败覆盖为首错并冻结，卡引脚CS高/SCK低/MOSI高。初始化及扇区读取各有外部10秒超时，START等待忙状态也有超时。无失败自动重试/擦除锁存。

这不是完整文件双CRC通过：921654B BMP文件CRC32=47E2A01D、解码后SDRAM标签CRC32=A1E4D4E1仍留下一步。原初始化器固定假设SDHC，未新增OCR/CCS识别，沿用受控卡契约；不把模型OCR应答当实际识别证据。TF区64..1864，PCM从2048起，诊断不访问PCM。

TD最终：**{result['measured']['mslices']}/4900 MSlice、{result['measured']['lut']} LUT、{result['measured']['reg']} REG、10×9K/0×32K、0 DSP/3 PLL**；Setup **{result['sta']['setup_wns_ns']:+.3f}ns**、Hold **{result['sta']['hold_wns_ns']:+.3f}ns**，**0/0**。保留全部阶段原文，路由阶段RUN-6004单端网告警1条OPEN；出位阶段0新增告警，不据此抹去路由告警。物理容量余量3777 MSlice。

CDC：9个逻辑首级D映射为10个物理精确引脚，其中7个实际时序首级端点、3个PLL硬宏输入查询（两个逻辑PLL源）；219个动态冻结数据D端MC4/3，229个精确查询，源域D/CE误豁免=0、像素误豁免=0、别名OPEN=0。无新增TF CDC。TF全部455位原生寄存器均核验BASE钟域及实际物理Q连接，四个TF引脚B14/A14/A13/A12与原ADC一致；MISO无false-path，输入max10/min0、输出max2/min0为沿用设计预算，未测真卡/板级延迟。

原生S1计数58位、独立参考29个LOGIC锥、M1R快照321位、32位DQ I/O捕获继续核验。审计器补充FX数据锥：依据本机安路EG_PHY_MSLICE specify，包含两组a..d及本路mi，所有依赖保持LOGIC；排除门级/物理之间不具有身份的open_n编号作为网络别名。没有RTL修补、没有扩大例外范围；place和route生成的physical.sdc SHA一致。主板真实时钟绝对频率、真卡I/O延迟及加密HDMI内部行为仍由上板约束验证。

Verilator --assert：实际SPI针脚假卡8项（正常复读及复位、无卡、数据CRC错、扇区内容错、初始化静默、读取静默、首通过后的CRC错、字节乱序）全部通过；故障回归缩短计时与轮询，SPI分频保持。另以交付默认全部参数跑正常复读及复位通过（仿真507ms），不代签10分钟硬件运行。实际顶层16页、完整CRC32高低半字及M1/S1故障显示通过。新包装默认严格lint 0/0，应用-Wall lint {next(r['warnings'] for r in lint if 'application' in r['path'])}告警OPEN/0错误，既有假卡模型的编译告警OPEN。模型与编译输入SHA绑定，不用HDMI/PLL替身证明硬件功能。

历史M1R284项、初读2项、长稳3项及81项受保护资产校验通过；全部复用驱动/自检源逐字SHA核对。旧位与旧证据不改写。

## 真卡操作与读数

插入原受控TF卡，将本位烧到主板。复位按键约1秒（RTL KEY1，本板丝印KEY2），放开等12秒。彩条应一直正常；SW0=1，每页等0.3秒：

| 页 | 预期十进制 | 含义 |
|---|---:|---|
| d0 | 05468 | TF1版本 |
| d1 | 00127 | 初始化、读请求、512B、CRC及成功七项通过 |
| d2 | 00000 | 首错码；非零保持运行并记录全部页 |
| d3 | 00512 | 完整扇区字节数 |
| d4 | 00112 | 初始化原内部debug，完成静止值 |
| d5 | 24356 | 首扇区CRC32低16位5F24 |
| d6 | 62544 | 首扇区CRC32高16位F450 |
| d7 | 65280 | 固定校验页FF00 |

SW0=0：P1成功次数约4次/秒递增；P2=0（初始化/读R1均0）、P3=112（锁存请求WAIT_READ=3/reader IDLE=16）、P4=16639（S1健康）、P5=127/P6=0（M1R通过/无错），P0/P7同版本/校验页。十秒外部watchdog按BASE时钟设计，等12秒保证初始化或读取静默也会有结果。P1连续读两次、间隔2秒，应明显增加。

错误码d2：17/18/19为原初始化错误1/2/3；33..38为原reader错误1..6（37=数据CRC16）；224=等初始化忙超时、225=初始化静默超时、226=等reader空闲超时、227=读取静默超时、228=字节次序、229=字节数或CRC未完成、230=CRC计算重叠、231=首扇区CRC32/受控素材不符、239=包装非法态。d1位7置位，d4为原init debug；P3高3位为包装锁存态、低5位为reader态，P2保留两种R1。首次成功后的故障d1=255，以首错为准。

先反馈初始d0～d7及P1两次/P4～P6和彩条；异常不再复位。初读通过后持续≥10分钟，确认P1增长、d1/d2及P4/P5/P6无故障，最后复位重复读数。真卡通过才进入完整受控加载及双CRC，之后恢复完整效果。本独立BASE域成功不能单独证明原A4失败源于MISO或CTRL依赖。
'''
if report.exists():
    assert report.read_text(encoding='utf-8') == text
else:
    report.write_text(text, encoding='utf-8')
excluded = {'obj', 'obj_default', 'obj_dir', '__pycache__'}
paths = [p for p in WORK.rglob('*') if p.is_file() and not excluded.intersection(p.parts) and p.name != 'core']
paths += [target, delivery, report, Path(__file__).resolve(), ROOT / 'scripts/prepare_tf1.py',
          ROOT / 'doc/brief/BOARD_DIAGNOSTIC_PROGRESS_TF1_20261006.md']
save(ROOT / 'doc/output/TF1_EVIDENCE_INDEX_20261006.json', dict(
    status='SEALED_DIAGNOSTIC_NATIVE_AND_SOFTWARE', hardware_status='PENDING_TF1_BOARD_TEST',
    parent_board_evidence_sha256=sha(ROOT / 'doc/output/M1R_STABILITY_BOARD_EVIDENCE_20261006.json'),
    bit_sha256=sha(bit), files=[dict(path=p.relative_to(ROOT).as_posix(), bytes=p.stat().st_size, sha256=sha(p))
                              for p in sorted(set(paths))]))
print(json.dumps(dict(bit=target.as_posix(), sha256=sha(bit), measured=result['measured'], sta=result['sta'],
                     sealed_files=len(set(paths)), prior_verified=verified), ensure_ascii=False))
