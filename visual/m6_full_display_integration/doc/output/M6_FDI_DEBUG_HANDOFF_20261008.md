# M6-FDI 调试交接（2026-10-08）

> 最后核对日期：2026-10-08；维护者：Codex。§1–9 为历史阶段记录；P1N 真板结果见 §10，P2 执行见 §11。

承接 `M6_FDI_DEBUG_HANDOFF_20261007.md`。工作根目录：
`D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration`

## 1. 一句话现状

**PCB 线稿从未在真板上显示过。** 完整工程（F1～F8）始终失败，失败点随每次布局跳动，均为 RTL 不可能状态。已改为“在真板已验 L1 上一次只加一块”的路线；第一步 P1（L1 + 静态标签直出）**真板失败**：加载器卡在 BOOT，且画面每隔几秒闪黑。根因未确认。

用户决定：后续调试统一引入**网口探针**（PC 抓包实时观测），并在后续阶段用 PC 模拟从板发频谱。

## 2. 真板已验基准（勿改）

| 位 | 短 SHA | 结论 |
|---|---|---|
| L1（TF 全文件加载 + SDRAM 双 CRC + 彩条） | 0AF5C5AF | ✅ 2026-10-08 再次复测：d1=127，放 2 分钟**不闪** |
| TF1 / M1R / S1 | 9345F2B7 / 685BC8D3 / 4BA41B2F | ✅ 历史已验 |
| 原第四步显示基座（网络 + 128 柱） | 75959E68 | ✅ |
| 副板 FFT | 7175ECC3 | ✅ 保持不变 |

环境已排除：L1 同板同卡正常；P1 换 5V 外接电源仍闪；下载方式为 SRAM，Flash 中旧位已被用户删除；P1 运行时 d0=05480 确认是 P1 本身。

## 3. 本轮（10-07 夜～10-08）各位结论

| 版 | d0 / 短 SHA | 内容 | 真板结果 |
|---|---|---|---|
| F6 | 05475 / 67378545 | 只读探针 | **完整工程首次加载+双 CRC 通过**（d1=255），READY 后报 **0x45**（显示读越界），watchdog=0；同一复位源两个物理副本读值相反 |
| F7 | 05476 / 8704DCC4 | 冻结越界地址探针 | 未到 READY：SD 初始化通过，**SDRAM 引擎卡在上电态 ST_PWR_UP**，10 s 后 0x46；无任何读请求 |
| F7C | 无位 | ChipWatcher 67 路 | 插入成功但 MSlice 4879、Setup −0.738/113 违例、物理约束重映射把多周期误套到设计路径 → **未出位**，中间件保留 `experiments/full_cw_F7C/` |
| F8 | 05477 / BD0237BD | 控制域复位只由 KEY1、经 GCLK 分发；PLL 失锁/复位事件计数 | d1=225、d2=**0x83**（SD 初始化 Ncr 超时）、d3=0、d4=0 → **无 PLL 失锁、无控制域复位事件**，复位毛刺假设基本排除 |
| **P1** | 05480 / **1BD7CEC0** | L1 源逐字节保留 + `fdi_label_stream` + 直出显示 | **失败**：一直彩条；SW0=1 d1=33、d2=0；SW0=0 页1=0x5000（loader **BOOT**、SDRAM 已 init、SD/reader 闲置）、页4=0x40FF（S1 健康、无 PLL 失锁、无 ctrl 复位）；**约 10 s 后开始每隔几秒闪黑**，LED1/LED3 常亮不变（与闪无关） |

P1 位：`deliverables/M6_FDI_P1_20261008_1BD7CEC0.bit`，SHA256 `1bd7cec0b1997e7a2aca22d6c81454d8c6bff95b3768656cd83a3e67dea28bcb`，631971 B。实现门禁：MSlice 1183、Setup +3.17 / Hold +0.035、0/0、CDC PASS_PRECISE_SCOPE、BIST 审计 PASS；RTL 仿真两整帧 614400 像素与金值逐像素一致（`experiments/stage_P1_label/sim/p1/run.log`）。

## 4. 已确认事实与已撤回推测

已确认：
- 同一加载器 RTL：L1 布局能工作，P1/F 系列布局失败 → **故障对物理实现敏感**，而非新增模块功能。
- L1 与 P1 网表：EG_PHY_CONFIG 参数完全相同；95 个 IO PAD 配置逐项相同。
- P1 期间无全局复位（observer ctrl_reset_seen=0）、无网络 PLL 失锁。
- P1 闪黑：彩条一旦切走只能由像素域复位切回；全局复位已排除 → 闪黑最可能是**视频 PLL 周期失锁或 HDMI 链路重同步**（未证实）。

已撤回（不要再沿用）：
- “PLL 锁定毛刺部分复位”为根因 —— F8 事件计数为 0，基本排除。
- “芯片周期性重配置/跑 Flash 程序” —— d0=05480、LED 不变，撤回。
- F6 d5 bit5 与 d1 不一致 —— 仅诊断副本 `ctrl_reset_sync[1]_dup_37` 只驱动数据输入，不是功能故障。

未确认的嫌疑方向（按优先级）：
1. 50 MHz 时钟（clk_50 直接从 PAD 进 clock mesh，**无 EG_PHY_GCLK**）在大扇出/不同布局下的物理质量；加载器与视频 PLL 参考都依赖它。
2. 工具生成网表本身的功能错误（可由网表仿真判定，见 §6）。
3. 某类 STA 未覆盖的路径（异步复位 recovery/removal 已在报告中，未见违例）。

## 5. 下一步建议（用户已定方向）

**P1N：P1 + 只发网口探针**（用户已认可网口调试路线）
- 复用 052 已验 RGMII 发送（`vendor/udp_base/import/rgmii_interface.v` + ODDR），L1 时钟树空闲的 `clk_125`/`clk_125_90` 直接可用。
- 每 1 ms 广播一帧原始以太网帧（无 IP/ARP），载荷：loader state/watchdog/error、snapshot 低位、eng_init、init_ready、视频 PLL lock、像素复位次数、帧计数、BASE50 心跳、reset 事件计数。
- PC 用已验过的 pktmon/Wireshark 抓包，得到毫秒级时间线；重点对齐“闪黑时刻”与 loader/PLL 状态。
- 探针纯只读；加入后若故障消失/变形，本身即“布局敏感”证据。
- 预计 +100～200 MSlice。

**之后 P2～P4**：在 P1 稳定后依次加 128 柱（测试图案）→ W2/S2 → 网络与真实频谱；网络阶段由 PC 模拟从板发 292 B/type2 频谱（Python 标准库 socket，无新依赖；注意主板校验对端 MAC，需改 PC 网卡 MAC 或调试时放宽）。

## 6. 未完成/中止的工作

- **P1 网表零延迟功能仿真**（判别“工具网表错”还是“硅片/板级”）：已在 `/tmp/p1_netsim/`（即 `C:C:/Users/KoneFly/AppData/Local/Temp/p1_netsim`）编译通过（官方 `sim_release/eg4/*.v` + `route_netlist.v` + 卡模型 + `tb_p1_net.sv`），运行中被用户中断并已停止进程，**无结果**。接手者可直接 `vsim -c work.tb_p1_net work.glbl -do "run -all"` 继续，观测 30 ms 内 state 是否 BOOT→INIT。
- F7C ChipWatcher：放弃（面积/时序/重映射三重问题），中间件保留。

## 7. 构建流程要点（新增经验）

- 完整工程：`scripts/td_chain.sh <实验> <后缀>`（LogicLevelOptimize、place seed2、route high/线程1、hold clock→pad、签核、出位）。**脚本运行中不可编辑**，bash 边读边执行，曾因此打乱 F8 一次后续阶段（`hold_f8_clock`/`hold_f8_pad16` 空目录为该事故残留）。
- route 局部冲突：`-RouteStrategy repair -RouteEffort high -FlowThreads 16` 已两次成功。
- bit 模式要求输入目录已有 `CDC_AUDIT.json`/`ROM_AUDIT.json`，否则准备阶段失败（`bit_f7` 空目录残留）。
- L1 系流程（P1）：`scripts/run_m1.ps1`；MISO 保持违例用 `FDI_HOLD=buffer`（插缓冲 LUT，与 L1 同类），未使用 F 系 PAD INDEL=16。
- 生成脚本均拒绝覆盖：`scripts/prepare_f7_probe.py`、`prepare_f8_harden.py`、`prepare_f7c_chipwatcher.py`、`prepare_p1_label_view.py`。
- PowerShell 执行策略为 RemoteSigned，直接 `powershell -NoProfile -File` 即可，勿加 Bypass。

## 8. 边界

本轮未改 TF 卡、未改 BURN_INDEX、未 git 操作、未修改 L1/TF1/M1R/S1 等已验实验目录（P1 为复制后新目录）。副板始终 7175ECC3。最终验收（完整线稿+动态+128 柱、≥10 分钟、复位复现）尚未开始。

## 9. P1N 接手执行结果与下一次板测

### 9.1 当前交付边界

**P1N 已出位并归档，未上板；PCB 线稿仍未获得真板显示证据，根因未定。** 实测与 SHA 的唯一机器清单：
[P1N_DELIVERY.json](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/experiments/stage_P1N_netprobe/doc/output/P1N_DELIVERY.json)。

- 版本：**P1N / 数码管 05481**，基底为真板失败的 P1。
- 待登记、待上板位：[M6_FDI_P1N_20261008_6AD3D8CE.bit](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/deliverables/M6_FDI_P1N_20261008_6AD3D8CE.bit)。
- SHA256 前16：`6AD3D8CE58418B8E`；完整 SHA、字节数、资源与时序引用上述清单。
- 位生成前，已将源码、约束、签核数据库、完整原生日志及必要验证证据冻结到 `experiments/stage_P1N_netprobe/td_run/archive_p1n_d2fd5e8a/`，132 个文件逐 SHA 核验。位生成后核对同数据库输入与同物理逻辑，并追加位阶段归档。
- **BURN_INDEX 未修改**：FDI 启动包 §3.3 将登记交由主人/规格方。本清单状态为 `EXTERNAL_OWNER_PENDING`，登记时使用上面的实际位路径与前16 SHA，标记 **P1N 只发探针 / 未上板**。

独立工程：`experiments/stage_P1N_netprobe/`。加载器、SPI、SDRAM 引擎及 `fdi_clock_tree.v` 与 P1 逐字节一致；顶层、视频模块只增加只读观测和探针输出，原 ADC 追加六个已验 TX 管脚，原约束逐条保留，仅增加本探针的精确 CDC 与发送时钟预算。没有改 GCLK 分发方案，没有改 TF 卡、043 主线或副板。所有新工程过程文件和归档在 D 盘。

首轮只发接入错误及时序失败的阶段均保留，无位：整模块 RGMII 的未连接 RX IDDR 被 TD 拒绝映射；修为六个原厂 ODDR。随后布线发现两个异步像素状态直接进入 BASE50、字节选择与 CRC 串联过长；修为只读两级同步及注册发送字节的 CRC 流水。

最终原生 Setup/Hold 正裕量、0/0 违例；strict lint 0 错/0 警；综合告警签名相对 P1 无新增，最终位阶段无告警。精确 CDC 与 32 条 DQ 路径通过。物理 `pixel_ready` LUT 同时通往新增 ready 首级和原 shown 首级，二者均在独立显式豁免名单中：已逐源级身份核对重叠，未改变 SDC，也未放行任何功能 FF/CE 的额外例外。

本轮没有恢复 §6 的网表仿真，也没有跑新 RTL 仿真；PC 解码器仅用独立构造的捕获文件验证字段、FCS、大小端、重复包、丢包及截断处理。实际网口发包和显示仍待真板。

### 9.2 探针与读数

每 125000 个 125MHz 时钟发一帧，名义周期 1ms。仅 TX、广播，无 IP/ARP；源 MAC `02:FD:49:00:00:01`，EtherType `0x88B5`，载荷80字节、魔数 `M6NP`。报文定义见 `project/src/rtl/fdi_net_probe.v` 与 `scripts/decode_p1n.py`，诊断字段小端。

载荷包括：发送序号/毫秒计数、视频帧计数、视频 PLL 失锁次数、像素复位次数、快照年龄、新鲜度、BASE50 心跳、完整29位 watchdog、112位原快照、加载器实时状态/故障、SDRAM 初始化计数、既有状态/标志、读地址、文件与内存 CRC、BASE50 快照序号。加载器复位事件计数放在 `read_flags[15:8]`，饱和255，只由 KEY1 清除。

快照采用请求/应答冻结总线，ACK 两级同步后再等三拍取回；发送期间冻结总线不更新。即便 BASE50 未应答，TX 仍发上一份快照并标记 `fresh=0` / 快照年龄增加。125MHz 发送域不随加载器复位清除；若其 PLL/参考本身停钟，也无法继续发送，此时要结合 PC 时间戳、包序号和网卡错误计数判断。视频 PLL/像素复位计数由125MHz同步采样，不能以零计数排除所有小于采样窗口的毛刺。

### 9.3 板测与抓包（本次只做这一位）

1. 主人/规格方登记本位后，保持现有受控卡及副板 **7175ECC3**，用 SRAM 烧录 P1N。确认 `sw[3:1]=000` 时版本为 **05481**。
2. 主板直连本 PC 的 **“以太网” / Realtek PCIe GbE / D4-D8-53-39-2A-D8**，确认链路为 **1Gbps**。不改 IP/MAC，不发送频谱测试包。
3. 以管理员身份打开 PowerShell，进入以下目录（当前 Codex 进程访问 PktMon 驱动已实测返回“拒绝访问”，不能代启动）：

   `D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/experiments/stage_P1N_netprobe`

4. 运行 `pktmon list`，找到 Realtek 的 **组件 ID**。这个 ID 不是 `Get-NetAdapter` 的 ifIndex=7。确认 `pktmon status` 没有别的抓包会话，`pktmon filter list` 没有阻挡本帧的既有过滤器；本脚本不删除全局过滤器。

```powershell
# 把123替换为pktmon list中Realtek的组件ID；换轮次用新Name，拒绝覆盖。
./scripts/capture_p1n.ps1 -Action start -Name board01 -ComponentId 123
```

5. 抓包启动后单按 KEY1 复位，观察至少60秒。若出现闪黑或无信号，在另一终端用同一目录执行标记（尽量在发生时按回车）：

```powershell
./scripts/capture_p1n.ps1 -Action mark -Name board01 -Event screen_black
```

6. 管理员终端结束抓包并自动转换、解码：

```powershell
./scripts/capture_p1n.ps1 -Action stop -Name board01
```

结果在 `doc/output/capture/board01/`：`probe.etl`、`probe.pcapng`、`timeline.csv`、`timeline.json`、时间标记及网卡起止统计。脚本只停止与自己日志路径相同的会话。若已有 Wireshark，可用显示过滤器 `eth.type == 0x88b5 && eth.src == 02:fd:49:00:00:01` 实时看本探针帧；也可将保存的 PCAP/PCAPNG 交给 `decode_p1n.py`。

本次反馈：**05481是否正确；是否见线稿/仍彩条/无信号；是否闪黑及大致开始时间；网卡链路速率；抓包结果目录**。不先动 TF 卡、不改供电、不开 P2。

判断优先级：

- 有连续包但 `fresh=0`、快照年龄上升、BASE50心跳不推进：先定位 BASE50/请求应答路径；不能仅凭这一项宣布时钟根因。
- 黑屏时间附近视频 PLL 失锁/像素复位计数递增：优先追视频时钟与复位时序。
- 这两类计数不增但视频帧计数推进、视频链路状态变化：优先追 HDMI 链路；暂不宣告 PLL 已被绝对排除。
- 无探针包：先核对网卡速率、抓包组件/过滤器和网卡错误计数，不能直接判定 FPGA 停钟。
- 如果 P1N 因改变布局而恢复加载/线稿，先记为布局敏感的对照结果；稳定板测后才依序推进128柱测试图案 → W2/S2 → 网络真实频谱。

---

## 10. P1N 真板上板结果（2026-10-08，浮浮酱追加）

### 10.1 结果：**PCB 线稿首次真板显示** ✅

| 项 | 值 |
|---|---|
| 位 | `M6_FDI_P1N_20261008_6AD3D8CE.bit`（SHA前16 `6AD3D8CE58418B8E`）/ 数码管 **05481** |
| 屏幕 | **线稿**（PCB 线稿首次真板显示）、**无闪黑** |
| 观察时长 | 主人观察 **5 分钟** |
| LED | **LED1/2/3 亮、LED4 灭**；已核对固件：S1 自检正常、标签 READY、视频锁定；加载器故障/BIST失配/控制复位sticky/网络PLL失锁sticky均未置位 |
| 网卡 | **1 Gbps** |
| 抓包产物 | `experiments/stage_P1N_netprobe/doc/output/capture/board01/`（probe.etl / .pcapng / timeline.csv / .json / adapter_stats_*） |

### 10.2 网口探针判读（timeline.csv）

- **稳态全程**：`video_pll_lock=1` / `network_lock=1` / `video_link_lock=1`；`pixel_reset_count=0`；`store_reset_events=0`；`file_crc=47E2A01D`、`memory_crc=A1E4D4E1`（均正确）；`loader_state=10`；`watchdog` 小值（**未卡 BOOT**）；`fresh=1` / `snapshot_age_ms=0`。
- **唯一一次复位 = 主人手按 KEY1**（`sequence` 948651→9、`watchdog` 重启、`pixel_frames` 重置），约 **1 s 内重新加载完成**（`loader_state` 回 10、`file_crc` 恢复）。
- `video_unlock_count` 稳态=1（**上电初始化期**累计），复位后归 0 且未再增长 ⇒ **运行期无失锁**。

### 10.3 决定性对照（"布局敏感"由推测升为实证）

| | P1（同日） | **P1N（同加载器 RTL + 只读探针）** |
|---|---|---|
| 屏幕 | 一直彩条 | **线稿** |
| 闪黑 | 每几秒一次 | **无** |
| 加载器 | 卡 BOOT | 正常、双 CRC 正确 |
| 复位 / PLL | — | **0 意外复位、0 运行期失锁** |

⇒ **同一份加载器 RTL，仅物理布局不同，一个全挂、一个全好** ⇒ §4"故障对物理实现敏感"**实证成立**；§9.3 最后一条预判（"P1N 因改变布局而恢复 ⇒ 记布局敏感对照"）**命中**。

⇒ **根因方向收敛**：§4 嫌疑① —— `clk_50` 直接从 PAD 进 clock mesh、**无 `EG_PHY_GCLK`** —— **建议优先评估"50 MHz 时钟分发加固"**（走 GCLK / 全局缓冲），可能一次性消除该"布局抽签"根因，比逐块赌布局划算。

### 10.4 下一步（接手）

1. **先补稳定性长测**（≥10 min 不闪黑）并记录数码管/屏幕。
2. P1N 稳定后，按序推进 **P2（128 柱测试图案）→ P3（W2/S2）→ P4（网络 + 真实频谱，PC 模拟从板）**。
3. ⚠ **每加一块都改布局 ⇒ 可能再次触发**；每步必须**独立出位 + 上板复验**（不合并批次）。
4. 建议在 P2 之前插入 **"50 MHz 时钟加固"评估**（见 §10.3）。

### 10.5 接手后的补充读数与证据范围

针对“继续至≥10分钟并补读数”的询问，主人回复：**“始终显示完整线稿、无闪黑；页1 p153258、页2 p21800”**。页1为十进制53258=`0xD00A`：loader READY(10)、SD已初始化、SDRAM已初始化；页2=1800，对应标签最后扇区编号。回复没有另报精确分钟数，明确量化记录仍为 §10.1 的5分钟；该回复作为追加稳定性反馈保留，不代写新的精确时长。

`board01` 捕获有37476个解码样本、11117个序号不连续位置；复位后的覆盖窗口约347.7秒。网卡广播包计数增加361234，接收错误/丢弃计数均未增加。捕获文件未覆盖每个名义毫秒，不能把这些间隙直接认定为FPGA发送丢包，也不能把采样结果表述为无盲区监测。已有视觉反馈、正确双CRC、READY读数及采样事件计数支持P1N的已验结论；未证明具体根因就是GCLK缺失。

## 11. P2：128柱测试图案（2026-10-08，已出位、待登记/上板）

工作区：`experiments/stage_P2_test128/`；基底为已验 P1N `6AD3D8CE58418B8E`，回退仍为同一P1N位。所有已验实验与位保持。

主人本次要求按序推P2，并指出原28px高度太低。当前P2据此采用**最大56px、底带y=423..479、128列、4px柱+1px间隔**；原线稿非零前景优先显示，柱图只绘在空白背景，保留完整线稿。四种图案按整帧轮换：阶梯、奇偶满高/空柱、逐列单柱、移动波形；每种128帧，总周期512帧（名义约8.53秒）。后续真实频谱阶段按这个高度尺度验证；本位不声称已验证歌曲频谱。

没有并入W2/S2、真实频谱或RX，也没有插入50MHz时钟分发修改。原ADC、逻辑SDC、加载器/SPI/SDRAM/时钟树逐字节保持。P2只新增像素域测试模块，视频端接入；数码管/探针版本更新为05482，报文布局、MAC、EtherType和周期保留。

首轮布线Setup −0.273ns、3违例、Hold正，未出位；同一布局高努力布线无改善。最差路径为探针schedule到octet计数器，连线约占82%。后续仅对倒计时开始条件做等价预计算寄存：提前解码schedule=1，下一拍与原schedule=0开始条件同拍。256个有限状态/tick组合归纳核对通过，不改变实际发包拍点、字段或周期，不放松原约束。旧阶段全部保留。

当前证据：[P2_STATIC_CHECKS.json](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/experiments/stage_P2_test128/doc/output/P2_STATIC_CHECKS.json)、[P2_LINT.json](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/experiments/stage_P2_test128/doc/output/P2_LINT.json)。编译0错0警；没有运行新RTL或全链路仿真。修正版完整TD已通过，原约束0/0违例、综合告警签名无新增、最终阶段无告警，精确CDC及32条DQ路径通过。

### 11.1 交付与归档

- 版本：**P2 / 05482**。
- 待登记、待上板位：[M6_FDI_P2_20261008_56ED2CD3.bit](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/deliverables/M6_FDI_P2_20261008_56ED2CD3.bit)。前16 SHA：**`56ED2CD3008433D6`**。
- 完整SHA、资源、时序及归档身份的机器清单：[P2_DELIVERY.json](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/experiments/stage_P2_test128/doc/output/P2_DELIVERY.json)。
- 出位前归档 `experiments/stage_P2_test128/td_run/archive_p2_4808b6df/`，117个文件逐SHA核对；位阶段另归档57个文件，并核对同输入数据库、同生产源码、同物理逻辑及同签核值。
- 回退：[已验P1N](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/deliverables/M6_FDI_P1N_20261008_6AD3D8CE.bit)，数码管05481；不覆盖本位及其源码、捕获或封存实验。
- **BURN_INDEX的P1N行保持主人/规格方的“线稿首现”结果。P2外部登记仍由主人/规格方按FDI启动包办理**，本次未代写该索引；P2目前不是硬件PASS。

### 11.2 本次板测（只烧P2）

1. 登记P2实际路径/SHA后，用SRAM烧录，现有TF卡、供电、副板7175ECC3保持。确认数码管05482。
2. 检查完整线稿持续显示；底部128列、4px柱/1px间隔，最左/最右列无错位。可按八组色带逐组核对，每组16列。线稿下沿有原非零像素时，前景优先会让柱体局部避开原线条，这是本次保留线稿的行为。
3. 观察四种图案按约2.13秒一组轮换：阶梯 → 奇偶满高/空柱 → 从左到右逐列单柱 → 移动波形；最大高度56px，顶端高光与峰值帽可见。完整循环约8.53秒。
4. **连续运行≥10分钟，并明确回报总观察时长**、有无闪黑/红屏/无信号/线稿丢失。单按KEY1复位，确认线稿与图案可重新出现，页1/页2及LED状态正常。
5. 主板仍直连Realtek以太网、1Gbps。管理员PowerShell进入 `experiments/stage_P2_test128/`，运行其自带捕获脚本，使用新Name，例如 `p2_board01`，不要在P1N目录覆盖旧捕获。

```powershell
# 123替换为pktmon list中确认的Realtek组件ID。
./scripts/capture_p1n.ps1 -Action start -Name p2_board01 -ComponentId 123
# 启动捕获后单按KEY1，记录至少60秒；发生异常时另终端执行标记。
./scripts/capture_p1n.ps1 -Action mark -Name p2_board01 -Event screen_black
./scripts/capture_p1n.ps1 -Action stop -Name p2_board01
```

脚本名称沿用，但此目录解码器已识别5482；输出CSV新增 `version`，用它区分P1N/P2。80字节诊断载荷、MAC、EtherType、1ms名义周期保持。≥10分钟视觉长测可与抓包分开，避免把捕获文件大小或采样间隙当作视觉验收时长。

反馈字段：**05482；完整线稿；128柱及56px高度是否合适；四图案/峰值帽是否正常；精确运行时长；闪黑/红屏/无信号；KEY1复位恢复；LED1–4；数码管P1/P2；抓包目录**。

P2复板通过后才推进P3（W2/S2）。主人要求的增高已记录为后续显示几何调整：底带y=423..479、最大56px；接入正式S2时须相应调整底带判定/高度与峰值换算/宽度，独立实测资源和时序，不静默沿用旧28px。当前P2没有验证真实歌曲频谱幅度响应。
