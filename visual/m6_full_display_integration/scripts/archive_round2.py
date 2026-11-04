"""只封存通过全部软件门禁的第二轮候选位；不登记外部BURN_INDEX、不写板。"""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import re
import shutil
import sys

TASK = Path(__file__).resolve().parent.parent
tag = sys.argv[1]
assert re.fullmatch(r'[A-Za-z0-9_]+', tag)
final = TASK/'td_run'/tag
OUT = TASK/'doc/output'

def sha(p):
    h = hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda: f.read(1024*1024), b''):
            h.update(chunk)
    return h.hexdigest()

def load(p):
    return json.loads(p.read_text(encoding='utf-8-sig'))

def write_json(p, data):
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')

def write_md(name, text):
    (OUT/name).write_text(text, encoding='utf-8')

r = load(final/'RESULT.json')
c = load(final/'CDC_AUDIT.json')
rom = load(final/'ROM_AUDIT.json')
manifest = load(final/'SOURCE_MANIFEST.json')
v = load(OUT/'ROUND2_VALIDATION.json')
gate = load(TASK/'td_run/checked2d/RESULT.json')
assert r['status'] == 'PASS_STAGE' and r['timing_pass'] and r['physical_gate_pass']
assert r['bit_status'] == 'GENERATED' and r['measured']['mslices'] < 4900
assert c['status'] == 'PASS_PRECISE_SCOPE' and not c['errors']
assert rom['status'] == 'PASS_ROM_INIT' and not rom['mismatches']
assert gate['status'] == 'PASS_STAGE' and gate['timing_pass']
assert v['frozen_round1_count'] == 61 and len(v['loader_cases']) == 11
assert sha(final/'production.sdc') == manifest['active_sdc_sha256'] == c['sdc_sha256']
assert sha(final/'route_netlist.v') == rom['netlist_sha256']
for rel in manifest['compiled_files']:
    assert sha(final/'src'/rel) == sha(TASK/'project/src'/rel), f'Final source drift: {rel}'
for rel in ['vendor/w2/pcb_dynamic_roms_w2.vh', 'vendor/fdi_stream/fdi_row_span_rom.vh',
            'constraints/eth_m6_master.adc', 'constraints/eth_m6_master.sdc']:
    assert sha(final/'src'/rel) == sha(TASK/'project/src'/rel)
assert load(OUT/'ROUND2_PREFLIGHT.json')['status'] == 'PASS_READ_ONLY'
assert load(OUT/'ROUND2_SOURCE_DIFF.json')['status'] == 'PASS'

bit = final/'eth_udp_m6_master_top.bit'
bit_sha = sha(bit)
assert bit_sha == r['bit']['sha256']
deliver = TASK/'deliverables'
deliver.mkdir(exist_ok=True)
candidate = deliver/f'M6_FDI_R2_20261005_{bit_sha[:8].upper()}.bit'
if candidate.exists():
    assert sha(candidate) == bit_sha
else:
    shutil.copyfile(bit, candidate)
assert sha(candidate) == bit_sha
bit_record = dict(status='CANDIDATE_GENERATED_NOT_BURNED',
    path=candidate.relative_to(TASK).as_posix(), sha256=bit_sha, bytes=bit.stat().st_size,
    native_source=bit.relative_to(TASK).as_posix(),
    source_manifest_sha256=sha(final/'SOURCE_MANIFEST.json'),
    route_db_sha256=sha(final/'route.db'), active_sdc_sha256=c['sdc_sha256'],
    hardware_burned=False, BURN_INDEX_registration='PENDING_OWNER_SPEC_WORKFLOW')
write_json(deliver/'ROUND2_BIT_MANIFEST.json', bit_record)
m, s = r['measured'], r['sta']
lineage = []
cursor = final
while True:
    ancestor = load(cursor/'SOURCE_MANIFEST.json')
    lineage.append(cursor.name)
    digest = ancestor.get('input_manifest_sha256')
    if not digest:
        break
    matches = [p.parent for p in (TASK/'td_run').glob('*/SOURCE_MANIFEST.json') if sha(p)==digest]
    assert len(matches)==1, f'Ambiguous or missing input manifest: {cursor.name}'
    cursor = matches[0]
    assert cursor.name not in lineage, 'DB lineage cycle'
placed_tag = next(n for n in lineage if load(TASK/'td_run'/n/'SOURCE_MANIFEST.json')['mode']=='place')
placed = load(TASK/'td_run'/placed_tag/'RESULT.json')
packing_count = placed['physical_gate']['packing_mslices']
placed_count = placed['measured']['mslices']
margin = 4900-m['mslices']
pct = m['mslices']/4900*100
gate_lut = gate['measured']['lut']
stage_table = []
for p in sorted((TASK/'td_run').glob('*/RESULT.json')):
    if not p.parent.name.endswith('1') and '2' in p.parent.name:
        x = load(p)
        stage_table.append(dict(tag=p.parent.name, status=x['status'],
            confidence=x['confidence'], measured=x['measured'], sta=x['sta'],
            constraints_valid=x.get('constraints_valid', False),
            signoff=(p.parent == final), result_sha256=sha(p)))
area = (final/'route.area').read_text(errors='replace')
pads = [p for p in re.findall(
    r'^\s*(\S+)\s+(INPUT|OUTPUT|INOUT)\s+([A-Z]\d+)\s+(?:LVCMOS|LVDS)\d+', area, re.M)
    if not p[2].startswith('S')]
pins = {name: pin for name, direction, pin in pads}
assert len(pads) == 54 and len({p[2] for p in pads}) == len(pads)
assert {n:pins[n] for n in ('sd_dclk','sd_miso','sd_mosi','sd_ncs')} == dict(
    sd_dclk='A14', sd_miso='B14', sd_mosi='A13', sd_ncs='A12')
warnings = dict(application_interface=dict(status='OPEN', count=342),
    canonical_gate=gate['warnings'], final_physical=r['warnings'],
    failed_intermediate_stages='Historical evidence retained; not used as final signoff',
    board_and_card='NOT_STARTED; not signed')
write_json(OUT/'ROUND2_WARNING_REVIEW.json', warnings)
measured = dict(status='PASS_SOFTWARE_GATES_BIT_READY_BOARD_PENDING', generated_utc=datetime.now(timezone.utc).isoformat(),
    final_tag=tag, canonical_gate_tag='checked2d', final_native_result=r, DB_lineage=lineage,
    physical_capacity_gate=dict(capacity=4900, measured=m['mslices'], positive_headroom=margin,
        target_4850_pass=m['mslices']<=4850, optimization_4410_pass=m['mslices']<=4410,
        utilization_percent=pct),
    gate_lut=gate_lut, cdc=dict(status=c['status'], false_data_endpoints=c['false_data_endpoints'],
        mcp_data_endpoints=c['mcp_data_endpoints'], exact_queries=c['exact_queries'],
        accidental_pixel_shift_mcp_endpoints=c['accidental_pixel_shift_mcp_endpoints'],
        source_D_CE_alias_exemptions=c['source_D_CE_alias_exemptions']),
    bit=bit_record, ROM=rom, warnings=warnings, pins=dict(external_count=54, overlap=False, TF={n:pins[n] for n in ('sd_dclk','sd_miso','sd_mosi','sd_ncs')}),
    intermediate_stages=stage_table, frozen_semantics='W2/S2/effects byte identical to round1; 61 frozen source items',
    hardware_acceptance='NOT_STARTED', actual_TF_card_write=False)
write_json(OUT/'ROUND2_MEASURED_GATE.json', measured)
report = f"""# M6-FDI 第二轮交付报告

2026-10-05。**软件门禁通过，候选 bit 已生成；上板验收待主人配合。** 标签加载改为受控 TF 固定 LBA，冻结效果、W2、S2及其余生产 RTL 保持字节一致。最终物理占用 **{m['mslices']}/4900 MSlice（{pct:.2f}%），正余量 {margin}**，通过≤4850目标；4410/90%争取项未达成，不作为已批准底线的失败。

## 原生 TD 实测与口径

| 指标 | 第一轮 | 第二轮正式综合 | 第二轮最终布线/出位 |
|---|---:|---:|---:|
| LUT | 21206 | {gate_lut} | {m['lut']} |
| REG | 16424 | {gate['measured']['reg']} | {m['reg']} |
| ERAM9K | 42 | {gate['measured']['bram9k']} | {m['bram9k']} |
| ERAM32K | 5 | {gate['measured']['bram32k']} | {m['bram32k']} |
| DSP / PLL | 18 / 3 | 18 / 3 | {m['dsp']} / {m['pll']} |
| MSlice | 5099，打包失败 | 不以LUT折算 | {m['mslices']}，余量{margin} |
| Setup WNS / 违例 | 原约束有别名问题，不能签核 | {gate['sta']['setup_wns_ns']:+.3f}ns / 0 | {s['setup_wns_ns']:+.3f}ns / {s['setup_violations']} |
| Hold WNS / 违例 | 原约束有别名问题，不能签核 | {gate['sta']['hold_wns_ns']:+.3f}ns / 0 | {s['hold_wns_ns']:+.3f}ns / {s['hold_violations']} |

综合数据来自 `td_run/checked2d/gate.area` 的原生 Utilization，最终数据来自 `td_run/{tag}/route.area`、`route.qor`、`route.timing`。MSlice数取最终物理网表EG_PHY_MSLICE实际计数；选中放置{placed_tag}的初次打包数{packing_count}，放置优化后{placed_count}，最终优化可继续变化。容量门禁按物理MSlice评定，不把映射LUT或混合统计Total_luts当成物理容量。

TD新综合流程的首次read_sdc存在未生效现象，正式综合签核为导入gate.db、清空并重读显式production.sdc后的checked2d；早期默认时钟报告排除。打包后逻辑FF名发生变化，place2d的原逻辑约束时序亦排除；placed_checked2d起使用物理端点约束。中间负裕量、失败修复尝试全部保留，只有本报告绑定的最终运行参与签核。

## 加载链与受控卡

RTL只读LBA64–1864，共1801次CMD17，固定磁盘BMP为640×480×24bit、921654字节，解码后的16bit标签为614400字节；末扇区54字节有效、458字节补零。文件CRC32 `47E2A01D` 与升地址16bit标签CRC32 `A1E4D4E1` 保持冻结值，扇区CRC16亦保留。MBR、FAT遍历、目录和簇链分支从标签生产链删除；原两份FAT RTL保存在reference/round1_fat32，不参与59份HDL编译。

受控PCM分区从LBA2048起，数据区LBA6144起，FAT32根目录WAV1.WAV–WAV4.WAV沿用052第五步契约。标签区与PCM分区无交集。PC工具 `scripts/make_controlled_card.py` 创建新128MiB镜像并验证双FAT和各素材完整簇链，拒绝覆盖/直接设备写入。完整制作、写卡和读回步骤见 `CONTROLLED_TF_CARD_V2.md`；label_only.img仅供标签测试。另已只读引用052真实短素材，产出 `sim/round2_card/label_pcm_short_real.img`，四槽10.1/12.2/14.3/16.4秒，镜像SHA `db41b9c551ccde1c0ecdad878e997357ff9443f56ff095096e69407933f3a5f0`；重建素材及上游SHA复核均通过，未写实体卡。8项工具正反例仍为合成数据，真实镜像验证单独登记；正式长曲布局与052另行统一。

读回CRC缓存改用已有16bit状态RAM，采用显式一拍读等待。MISO增加4个保留的EG_LOGIC_BUF身份缓冲以满足输入最小延迟；没有增加采样寄存器或改变SPI拍序。该物理延迟由最终TD STA验证，Verilator模型只验证逻辑恒等。

## CDC 约束范围

显式约束取代foreach/get_regs别名。门级52个首级FF D端点映射为最终101个物理数据端点，另有1024个W2谱输入D端点使用MC4 setup/MC3 hold并显式-end（CTRL接收时钟）。物理LUT/FF合并端点采用捕获时钟加through数据引脚过滤，避免同名扇出扩大到源域D/CE。

最终逐端点查询{c['exact_queries']}项通过；2048条MCP规则各支配1条路径，实际端点集合恰为1024项；像素域spectrum_hold移位寄存器误豁免为0、源域D/CE别名误豁免为0，**本轮约束范围无别名OPEN**。基座既有PHY↔clk50及按键例外保持。逻辑SDC与实际物理SDC分别封存，SHA见ROUND2_MEASURED_GATE/最终SOURCE_MANIFEST。所有物理约束使用实际捕获端点，没有放宽TF输入max10/min0及输出max2/min0预算。

## 验证、证据与告警

本轮11个真实SPI模型/SDRAM模型加载场景全部通过，含正常全307200像素、双CRC失败、无卡、首尾扇区CRC16错、错误LBA位置、慢token、非对齐及越界读取；正常启动实测24863814个50MHz控制拍，测试STARTUP_CYCLES=32、BOOT_TIMEOUT_CYCLES=60000000，不能冒充生产默认启动等待实测。正常与慢token场景均准确读取1801扇区。

61项冻结RTL/include/ADC字节身份检查通过，沿用第一轮2404批W2/1567408次写、2403显示帧/738201600像素对拍、40独立JS黄金帧/12288000RGB像素证据；未把旧FAT加载13用例列为本轮受控链验证。W2最大更新18276拍是复用的第一轮实测。加载链严格lint及W2严格lint均0告警；全顶层接口lint0错误、342告警OPEN，IP内部/物理模型不由接口lint代签。PC卡工具8项正反例通过。

最终路由ROM INIT解码512字逐项符合冻结行区段表，0不一致；未声称位文件读回或实体板ROM已验证。75份只读基座源身份、原基座bit、独立W2、黄金BMP/行表均复核通过；052/043/副板及已验收bit未修改。54个实际外部pad无冲突，TF A14/B14/A13/A12核对通过；SDRAM S系列为内部专用引脚。原始告警详见ROUND2_WARNING_REVIEW，不因0/0时序而销项。

## 位文件与后续验收

候选位：`{bit_record['path']}`，{bit_record['bytes']}字节。

SHA256：`{bit_sha}`。

出位由通过容量、最终0/0、CDC和ROM审计的route.db生成；身份链见 `deliverables/ROUND2_BIT_MANIFEST.json` 与 `ROUND2_EVIDENCE_INDEX.json`。主板P7沿用原显示位ID，不能区分该新位，烧录必须按完整SHA识别；副板7175ECC3保持。外部BURN_INDEX由主人/规格方登记，本包仅归档候选位，不代签。

推荐后续先制作含真实PCM的受控卡并读回验证，再配合主人烧录本候选位，核查上电线稿、频谱动态、底部128柱、无卡/损坏卡诊断及连续≥10分钟稳定性，按ROUND2_BOARD_RECORD填写。当前未写实体卡、未烧录、未上板；TF真音频应用层/043合体仍不在本包范围。容量已达到本轮目标，后续优先硬件验收，不为争取90%再改冻结效果。

## 重现

保留全部运行脚本、Tcl、源快照、DB、原生报告和审计。实际DB链（新到旧）：{' → '.join(lineage)}；放置种子与布线努力级别记录在各SOURCE_MANIFEST/run.tcl。每一步使用新Tag拒绝覆盖；`scripts/run_round2.ps1` 完整实现门禁。普通自动buffer Hold修复在>90%占用时会跳过，EG4不支持尝试的pre-route hold phys_opt；本轮以保留MISO缓冲和最终原生clock_opt实测闭合。该流程遵循单一受控读取路径、复用既有RAM/PLL，不增加通用文件系统或预留新效果。
"""
write_md('M6_FDI_ROUND2_REPORT.md', report)
write_md('ROUND2_PROJECT_LEDGER.md', f"""# M6-FDI 第二轮候选位登记

2026-10-05；状态：BIT_READY / BOARD_PENDING。

| 项目 | 记录 |
|---|---|
| 工程 | 本包project/src，59份HDL；W2/S2/效果冻结 |
| 位文件 | {bit_record['path']} |
| SHA256 | {bit_sha} |
| 最终TD | td_run/{tag}，Setup/Hold {s['setup_violations']}/{s['hold_violations']} |
| 面积 | {m['mslices']}/4900 MSlice，余量{margin}；{m['lut']} LUT/{m['reg']} REG/{m['bram9k']}×9K/{m['bram32k']}×32K/{m['dsp']} DSP/{m['pll']} PLL |
| 标签卡 | CONTROLLED_TF_CARD_V2.md；已有四槽真实短PCM共卡镜像，正式长曲另行协调 |
| 副板 | 7175ECC3保持 |
| 主板P7 | 继承05401显示ID，不作为新位身份 |
| BURN_INDEX | 待主人/规格方流程登记，本包不修改外部索引 |
| 卡/烧录/板测 | NOT_STARTED，不代签 |

第一轮PROJECT_LEDGER、报告、位门禁及证据保留为历史；本记录对应新的第二轮SHA链。
""")
write_md('ROUND2_BOARD_RECORD.md', f"""# M6-FDI 第二轮上板记录

状态：**NOT_STARTED**。候选位 `{bit_record['path']}`；SHA256 `{bit_sha}`。未写实体TF卡、未烧录、未代签，BURN_INDEX待主人/规格方登记。

| 判据 | 结果 | 实际证据待填 |
|---|---|---|
| 受控TF真实PCM镜像及写后读回SHA/verify | NOT_STARTED | 卡型、工具、镜像SHA、素材SHA |
| 主板候选位SHA一致；副板7175ECC3保持 | NOT_STARTED | 烧录记录 |
| 上电PCB完整线稿且无错位/撕裂 | NOT_STARTED | 照片/视频 |
| 音柱/峰值帽/电流/节点/彗星随频谱 | NOT_STARTED | 输入与录像 |
| 底部128柱、静音收敛 | NOT_STARTED | 静音/有声录像 |
| 无卡/CRC错可观察诊断 | NOT_STARTED | 数码管/LED记录 |
| 连续运行≥10分钟稳定 | NOT_STARTED | 时长、异常、录像 |

本轮卡制作保留052第五步PCM受控格式，不表示第五步真音频应用已合入本FDI位。P7不能区分新位，应使用完整SHA。
""")
(TASK/'README.md').write_text("""# M6-FDI 当前交付

第二轮受控LBA标签加载、面积收敛及精确CDC修复的当前结果见 [交付报告](doc/output/M6_FDI_ROUND2_REPORT.md)。

候选bit及SHA见 [位清单](deliverables/ROUND2_BIT_MANIFEST.json)；受控TF标签/PCM布局与PC制作、写卡、读回步骤见 [受控卡流程](doc/output/CONTROLLED_TF_CARD_V2.md)。软件门禁通过，上板记录仍为NOT_STARTED，由主人配合；外部BURN_INDEX待主人/规格方登记。

[证据索引](doc/output/ROUND2_EVIDENCE_INDEX.json)绑定当前源快照、TD、验证、bit与卡工具。第一轮报告/证据以及reference/round1_fat32为历史，不作为当前签核。
""", encoding='utf-8')

# 索引自身不递归入哈希；所有条目使用包内相对路径。
files = set()
for directory in ['scripts', 'tb/controlled_loader', 'project/assets', 'doc/brief']:
    files.update(p for p in (TASK/directory).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
for rel in manifest['compiled_files'] + ['vendor/w2/pcb_dynamic_roms_w2.vh',
    'vendor/fdi_stream/fdi_row_span_rom.vh', 'constraints/eth_m6_master.adc',
    'constraints/eth_m6_master.sdc']:
    files.add(TASK/'project/src'/rel)
for directory in ['sim/round2_loader', 'sim/round2_lint', 'sim/round2_card', 'deliverables']:
    files.update(p for p in (TASK/directory).glob('*') if p.is_file())
for d in set(['checked2d', 'place2d', 'placed_checked2d']+lineage):
    files.update(p for p in (TASK/'td_run'/d).glob('*') if p.is_file())
for p in (TASK/'td_run').glob('*/RESULT.json'):
    if '2' in p.parent.name:
        files.add(p)
        for name in ['console.log', 'run.tcl', 'SOURCE_MANIFEST.json']:
            if (p.parent/name).exists():
                files.add(p.parent/name)
for p in OUT.iterdir():
    if p.is_file() and (p.name.startswith('ROUND2_') or p.name in
        ['M6_FDI_ROUND2_REPORT.md', 'CONTROLLED_TF_CARD_V2.md', 'EVIDENCE_INDEX.json',
         'M6_FDI_INTEGRATION_REPORT.md']) and p.name != 'ROUND2_EVIDENCE_INDEX.json':
        files.add(p)
for rel in ['sim/w2_display_result.json', 'sim/w2_display_failure.json',
    'sim/evidence/verified_rgb_manifest.json', 'sim/evidence/verified_boot_silence_f299.png',
    'sim/evidence/verified_play_mid_f299.png', 'START_PROMPT.md', 'README.md']:
    files.add(TASK/rel)
entries = [dict(path=p.relative_to(TASK).as_posix(), bytes=p.stat().st_size, sha256=sha(p))
           for p in sorted(files)]
write_json(OUT/'ROUND2_EVIDENCE_INDEX.json', dict(
    generated_utc=datetime.now(timezone.utc).isoformat(), status='SEALED',
    scope='Current round2 software signoff and candidate bit; hardware NOT_STARTED',
    final_tag=tag, bit_sha256=bit_sha, files=entries))
print(json.dumps(dict(status=measured['status'], bit_sha256=bit_sha, mslices=m['mslices'],
                      headroom=margin, evidence_files=len(entries)), ensure_ascii=False))
