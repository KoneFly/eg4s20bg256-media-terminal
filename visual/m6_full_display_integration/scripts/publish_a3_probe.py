"""A3原生门禁通过后归档；不覆盖旧位，不代签真卡验收。"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys

BASE = Path(__file__).resolve().parents[1]
TASK = BASE / "experiments/board_0x46_A3_work"
RUN = TASK / "td_run" / sys.argv[1]
read = lambda p: json.loads(p.read_text(encoding="utf-8"))
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
r = read(RUN / "RESULT.json")
assert r["status"] == "PASS_STAGE" and r["bit_status"] == "GENERATED"
assert r["physical_gate_pass"] and r["timing_pass"] and not r["failure"]
cdc = read(RUN / "CDC_AUDIT.json")
assert cdc["status"] == "PASS_PRECISE_SCOPE"
assert read(RUN / "ROM_AUDIT.json")["status"] == "PASS_ROM_INIT"
assert read(RUN / "CLOCK_PROBE_AUDIT.json")["status"] == "PASS_PHYSICAL_CLOCK_PROBE"
subprocess.run([sys.executable, "-X", "utf8", str(TASK / "scripts/collect_probe_validation.py")], check=True)
software = read(TASK / "doc/output/SOFTWARE_VALIDATION.json")
source = read(TASK / "doc/output/SOURCE_VALIDATION.json")
digest = sha(RUN / "eth_udp_m6_master_top.bit")
name = f"M6_FDI_A3_20261006_{digest[:8].upper()}.bit"
bit = BASE / "deliverables" / name
report = BASE / "doc/output/BOARD_PROBE_A3_20261006.md"
manifest_path = BASE / "deliverables/BOARD_PROBE_A3_MANIFEST.json"
index_path = BASE / "doc/output/BOARD_PROBE_A3_EVIDENCE_INDEX.json"
for p in (bit, report, manifest_path, index_path):
    assert not p.exists(), f"Refuse overwrite {p}"
shutil.copy2(RUN / "eth_udp_m6_master_top.bit", bit)
manifest = dict(experiment="A3_CLOCK_COUNTER_READ_ONLY", bit_path=bit.as_posix(), bit_sha256=digest,
                bit_bytes=bit.stat().st_size, final_run=RUN.as_posix(), physical=r["measured"], sta=r["sta"],
                parent_bit_sha256="7b97635aadd6fa4ebab8f3fc598f195cde5bafcdf6b6968bf105ac62284cd57c",
                parent_hardware_status="FAIL_STALLED_BOOT_PWR_UP_NO_TIMEOUT_CODE",
                build_display="SW0=1 d0 05463; d7 constant 65280 calibration",
                hardware_status="PENDING_TRUE_CARD", bit_readback_verified=False,
                required="逐页实测；若线稿出现仍须稳定至少10分钟及KEY1复现；BURN_INDEX由主人/规格方登记。")
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
m, t = r["measured"], r["sta"]
report.write_text(f"""# A3 时钟/启动计数实验位（2026-10-06）

**已生成只读观测位，真卡待实测；未宣称故障修复。** A2 真卡无线稿：普通P0～P6零、P7=05401，诊断BOOT/PWR_UP在12秒后及间隔10秒重读均不前进，未观察到60070。

主板位：[{name}]({bit.as_posix()})，{bit.stat().st_size} 字节，SHA256 `{digest}`。副板仍用已验7175ECC3。
实验源/原始TD证据：`experiments/board_0x46_A3_work`；最终原生阶段 `{RUN.name}`。

A3相对A2只有只读观测与临时显示变更：watchdog、SDRAM cnt、原始CTRL心跳、复位/锁定、状态字与65280校准。MISO仍两级，PLL参数/连接、SPI速率/采样、SDRAM时序/握手、CRC、超时、卡布局、W2/S2及效果不变。四个文件的新增观测可逆还原A2；五个驱动功能正文还原原字节；94项源身份守卫、A2封存319项、R2封存400项、81项受保护资产核验通过。源差异保存为隔离版本 `doc/output/SOURCE_DIFF.patch`。

| 实测项 | 结果 |
|---|---|
| 最终物理MSlice | {m['mslices']}/4900，余 {4900-m['mslices']}；达到≤4850目标 |
| 物理LUT / REG | {m['lut']} / {m['reg']} |
| ERAM9K / ERAM32K / DSP / PLL | {m['bram9k']} / {m['bram32k']} / {m['dsp']} / {m['pll']} |
| 最终Setup / Hold | {t['setup_wns_ns']:+.3f}ns / {t['hold_wns_ns']:+.3f}ns，违例 {t['setup_violations']} / {t['hold_violations']} |
| 精确CDC | {cdc['false_data_endpoints']}物理首级数据端 + {cdc['mcp_data_endpoints']}多周期数据端；{cdc['exact_queries']}查询全部命中；别名OPEN/误豁免0 |
| ROM INIT | 512行通过，不代表bit读回验证 |
| 物理探针 | 16位心跳映射至9个物理单元，时钟逐单元追溯PLL C1/CTRL GCLK，异步复位逐单元追溯KEY1 PAD；不是内部CTRL reset |
| 软件回归 | 11加载用例、2故障快照用例、新增心跳/停钟/65280实际数码管转换测试通过 |
| lint | 加载/W2严格0告警；应用接口0错误/{software['application_lint_warnings']}告警OPEN |

新增应用告警为旧快照未消费位与新probe模块TIMESCALEMOD；诊断TB明确时标。原模型三项哈希一致，未调整SDRAM模型相位。综合初次SDC未正确加载的STA及布局阶段未重映射的别名告警保留为过程证据；最终口径只采用已重载准确物理SDC的原生报告，不用过程结果冒充最终签核。

## 真卡操作

1. 烧本位。SW0=1、页000应见 **d0 05463**；页111应见 **d7 65280**。d7为固定校准值，已经不是卡R1。
2. 按住KEY1约1秒应消隐；放开后保持SW0=1，读d4并观察约2秒，至少抄三次、每次相隔≥0.3秒，判断心跳是否变化。
3. 放开复位12秒后读取d1、d2、d3、d5、d6，再隔10秒重读d1、d3、d4。页切换至少等待0.3秒；记录完整前缀及数字，切页不复位。
4. 切SW0=0，记录普通显示及屏幕。若线稿出现，仍须观察至少10分钟、动态运行及KEY1复现；没有线稿或校准失败也照实回传，不再换卡或盲改驱动。

| 页 | 实时含义 |
|---|---|
| d0 | 固定05463，A3识别 |
| d1 | watchdog低16位 |
| d2 | [12:0] watchdog高13位；[13]ctrl_rst_n；[14]PLL locked；[15]key1 |
| d3 | [14:0]SDRAM cnt；[15]eng_init |
| d4 | 独立KEY1复位的CTRL心跳计数16bit，内部CTRL复位不能清零它 |
| d5 | [0]快照init_ready；[1]快照eng_init；[2]快照reader R1 bit7；[3]ctrl_rst_n；[5:4]ctrl_reset_sync；[6]全局reset；[7]PLL reset(!locked)；[8]key1；高位0 |
| d6 | A2原d1：store/init/reader状态、mem_busy/eng_init/init_ready |
| d7 | 固定65280(FF00)，校准数码管高位 |

watchdog恢复：`((d2 & 8191) << 16) | d1`。SDRAM cnt=`d3 & 32767`。心跳是自由滚动计数，回绕正常；多次变化仅证明持续有CTRL边沿，不能据两次十进制读数精确测频。普通bank无错误码不再作为“卡数据已读对”的证明。

SW0是RTL sw[0]，对应当前ADC的C8（注释板上SW1）；三个页位对应C7/C6/C5。RTL sw[3:0]从d0至d7为0001、0011、0101、0111、1001、1011、1101、1111；0/1指实际电平，不把丝印ON直接当1。

临时SW0=1 bank允许内部reset保持时观察，SW0=0优先级保留。所有观察没有加载控制反馈。若A3成功，新增观测引起物理布局改变，也不能据此唯一归因MISO/PLL；需结合计数和复位读数。真卡未测试，本包不代签硬件验收或上游登记。
""", encoding="utf-8")
paths = []
for directory in ("project", "scripts", "tb", "doc/output", "sim/probe_loader", "sim/probe_snapshot", "sim/probe_lint", "sim/clock_progress"):
    paths.extend(p for p in (TASK / directory).rglob("*") if p.is_file() and "__pycache__" not in p.parts)
for folder in (TASK / "td_run").iterdir():
    if folder.is_dir():
        paths.extend(p for p in folder.iterdir() if p.is_file())
paths.extend([bit, report, manifest_path, BASE / "scripts/prepare_board_probe_a3.py", Path(__file__).resolve(),
              BASE / "doc/brief/BOARD_PROBE_A3_SCOPE_20261006.md", BASE / "doc/output/A2_PROBE_STALLED_CONFIRMED_20261006.json"])
entries = [dict(path=p.relative_to(BASE).as_posix(), bytes=p.stat().st_size, sha256=sha(p)) for p in sorted(set(paths))]
index_path.write_text(json.dumps(dict(status="SEALED_SOFTWARE_ONLY", hardware_status="PENDING_TRUE_CARD",
                                      bit_sha256=digest, files=entries), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
for row in entries:
    assert sha(BASE / row["path"]) == row["sha256"]
print(json.dumps(dict(bit=bit.as_posix(), sha256=digest, evidence_files=len(entries), hardware="PENDING_TRUE_CARD"), ensure_ascii=False))
