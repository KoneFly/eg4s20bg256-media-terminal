# M6-FDI 调试交接（2026-10-07）

## 1. 接手结论与停止状态

**尚未完成完整显示验收。** 时钟/彩条、SDRAM 自检、TF 首扇区、完整标签图加载及双 CRC 均已分别上板通过；换到完整显示工程后，加载启动仍异常，屏幕无信号。当前最新上板版为 **F5，d0=05474，主板位 672560A2**。根因未确认，不能把仿真或时序通过当作真板修复。

用户要求本次停止调试并交接。已停止正在运行的 F6 TD 综合，保留中间文件；没有 F6 位文件。F6 仿真在停止前已完成，lint 已完成。停止时检查未发现仍在运行的 TD 进程。本次未烧录、未改卡、未提交 Git。

工作根目录：

`D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration`

后续遵守用户偏好：**只做最精简 debug，不插入不必要的文档归档或独立审查；最终正常验收后补齐必备文档。** 本文是本次明确要求的交接文档。

## 2. 目标、授权与边界

最终画面：PCB 完整线稿 + 冻结动态效果 + 底部常驻 128 柱。副板 **7175ECC3 保持不变**，只迭代主板位。

- W1 整体出列；粒子、柱顶连线不在本包范围。W2/S2、128 柱、冻结效果不能以调试或省面积为由裁减。
- 标签图和 PCM 仍使用受控 TF 卡；不采用 Flash。052/043 上游、既有验收位及封存实验不改写。
- 已验 SPI 驱动、SDRAM 引擎、卡校验路径不得盲目改写。复位/加载 glue 可按观测调整，但每次功能修改必须真板复现。
- 用户已授权资源范围内自主判断，不需要反复申请常规实施确认。
- 物理 MSlice 必须 **<4900，留正余量**；目标 ≤4850，争取 ≤4410。其它上限：REG 17640、9K 57、32K 14、DSP 26、PLL 3；W2 自身 DSP ≤2。
- 完整时序门禁 Setup/Hold **0/0**，包括 PHY RX 125MHz；精确约束命中、无源 D/CE 别名误豁免、无 pixel 域误多周期。
- 真板最终验收包含完整线稿、频谱动态、底部柱、≥10 分钟稳定及复位复现。不能代签。

原始启动包：
[START_PROMPT.md](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/START_PROMPT.md)。后续用户授权（受控 LBA、物理门禁、精简 debug）优先于启动包旧口径。

## 3. 已通过的真板分层验证

| 阶段 | d0 / 主板位短 SHA | 真板结果 |
|---|---|---|
| 原第四步显示基座 | 75959E68 | 用户确认画面正常，P1=1 |
| S1 时钟与彩条 | 05465 / 4BA41B2F | 彩条正常，所有指定时钟/状态读数正确 |
| M1R SDRAM 自检 | 05467 / 685BC8D3 | d1=127、d2=0，d5/d6=23130；≥10 分钟及复位复现通过 |
| TF1 首扇区 | 05468 / 9345F2B7 | d1=127、d2=0、d3=512；P1 增加，P4=16639、P5=127、P6=0；≥10 分钟及复位复现通过 |
| L1 全文件加载、SDRAM 双 CRC | 05469 / 0AF5C5AF | d1=127、d2=0、d3～d6=40989/18402/54497/41444，P4=16639；彩条、≥10 分钟及复位复现通过 |

M1 初版 05466 的刷新计数饱和误报已在 M1R 解决，不要重新作为当前故障。

L1 完整正常读数：`05469、00127、00000、40989、18402、54497、41444、65280`。

**证据边界：L1 证明同板同受控卡的完整加载/写入/CRC 可工作；L1 使用彩条，并未验证完整扫描/动态显示。** 全工程失败不能直接归为卡不兼容，也不能据 L1 宣告最终完成。

受控卡当前契约：标签 BMP 起始 LBA **64**，共 **1801** 扇区，到 LBA **1864**；输入文件 **921654 B，640×480 的 24bit BMP**，解码为 RGB565 **614400 B / 153600 个 32bit 字**，SDRAM 字地址 **0x040000～0x0657FF**。PCM 区从 LBA 2048 起，不能覆盖。文件 CRC **47E2A01D**，SDRAM CRC **A1E4D4E1**。本次没有修改 TF 卡内容。

## 4. 完整工程 F1～F5 的修改与真板结果

| 版 | d0 / 位短 SHA | 本版主要变化 | 真板读数和停点 |
|---|---|---|---|
| F1 | 05470 / 185FB6E2 | 全显示控制改为 BASE50；使用 L1 加载器；去掉 RTL 中 4 级 MISO LOGIC_BUF | d1=96、d2=0，其余主要探针为 0；P1=0，无信号。复位、再等 10 秒、冷启动均不变 |
| F2 | 05471 / EA0DB254 | 只读诊断扩展；综合改 LogicLevelOptimize，容量/时序收敛 | d1～d7=225/70/7629/32768/20513/16424/65280；60070，无信号。快照：加载 INIT、SD 初始化 CMD0_WAIT、SDRAM 已初始化，命令完成/超时事件未出现 |
| F3 | 05472 / C19139E1 | 只读诊断页重映射，功能沿用 F2 | d1～d7=97/0/112/4096/0/40192/65280；15 秒不变，P1=0，无信号。reader R1=0x9D 与 RTL 写入规则矛盾，不能按正常协议状态解释 |
| F4 | 05473 / C53C03B6 | 加载器从全局 reset 单独四拍释放；其它功能不变 | d1～d7=225/70/7629/20480/112/65280/65280；60070，无信号。SDRAM 完成，但加载器仍 BOOT，SD/命令/reader 为初始闲置态，直到全局 10 秒超时 |
| F5 | 05474 / 672560A2 | 加载器 BOOT 启动条件从 `watchdog==START_LIMIT` 改 `>=`；正常启动阈值不变 | **最新** d1～d7=96/0/0/4096/112/65280/65280；SW0=0 页001=0，屏幕无信号 |

F3 的 `0x9D`：reader 的 R1 复位为 FF，正常写入只接受 bit7=0；9D 既不是 FF，也不满足写入条件。该异常支持检查物理实现/复位一致性，**尚不能证明具体故障点**。

F4 启动比较门级 LUT 静态逻辑检查通过：watchdog=499999、BOOT 时应触发，邻值不触发。板上没有推进，原因未证实。F5 的比较器成为原生 RIPPLE 比较链，简单 LUT 检查器不支持，**未完成 F5 比较链功能核验**，不能声称其门级功能已证实。

F5 修改没有证明有效。各位的失败停点会随物理实现改变，后续不要继续无观测修改 SPI、延时或协议。

## 5. 当前 F5 读数的严格解释

F5 诊断页（SW0=1，SW[3:1] 选页；每页等待约 0.3 秒）：

| 页 | 含义 | 本次读数 |
|---|---|---|
| d0 | 版本 | 05474 |
| d1 | 加载状态标志 | 96 = 全局 reset 已释放、全局 ctrl_rst_n=1；SDRAM/SD 初始化、CRC、READY 均未置位，无故障码 |
| d2 | 故障码 | 0 |
| d3 | watchdog[28:16] | 0；**只说明高 13 位为 0，低 16 位未知** |
| d4 | snapshot[15:0] | 4096=0x1000：loader BOOT=0、SD init IDLE=0、reader IDLE=16、mem_busy=0、eng_init=0、init_ready=0 |
| d5 | snapshot[63:48] | 112=0x0070：命令 transactor IDLE=7、byte 引擎 IDLE=0，完成/超时为 0 |
| d6 | snapshot[111:96] | FF00：reader R1=FF、初始化 R1=00，均为复位值 |
| d7 | 固定标记 | 65280=FF00 |

因此当前停在 **TF 初始化请求以前，且 SDRAM 初始化完成位也没到达**。不能从 d3=0 推断看门狗低位必为 0；也不能从全局 ctrl_rst_n=1 推断加载器所有物理复位副本已释放。

F5 物理网表检查：加载器/数码管的寄存器时钟名称均为 `u_decimal/clk`（BASE50）；加载器四拍复位末级被复制成多个物理节点，其中 SDRAM init_done 寄存器用 `rst_n_dup_17`。已找到该复位副本由 loader_release[2] 经 BASE50 寄存产生。**目前未发现可确认的错误连接；仅静态连接检查，不能代替实际钟/复位观测。**

## 6. F5 交付与实现证据

主板最新位：
[M6_FDI_F5_20261007_672560A2.bit](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/deliverables/M6_FDI_F5_20261007_672560A2.bit)

SHA256：`672560a2317d8572656897bc750935b499edc33c6ca1821173ddbe30f6bd7c93`；636626 B。本次交接前重新核对过文件哈希。它是**实现门禁通过、真板功能失败的调试位**。

F5 独立完整 TD 最终实测：

| 项目 | 数值 |
|---|---|
| MSlice | 4452 / 4900，余量 448；满足底线/4850 目标，未达到 4410 优化目标 |
| LUT / REG | 15430 / 11474 |
| ERAM 9K / 32K | 43 / 5 |
| DSP / PLL | 18 / 3 |
| Setup | +1.037 ns，0 违例 |
| Hold | +0.020 ns，0 违例 |
| 精确 CDC 范围 | PASS；87 false 数据端点、1024 多周期数据端点、1145 精确查询；源 D/CE 别名误豁免=0，pixel 误多周期=0 |
| 行区段 ROM | 物理网表 BRAM INIT 512 字逐字 PASS；不是上板回读证明 |

证据目录：
`D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/experiments/full_start_F5/td_run/bit_f5_logic/`

接手优先查看 `RESULT.json`、`CDC_AUDIT.json`、`ROM_AUDIT.json`、`route_netlist.v`、`production.sdc` 和原生 TD 日志。最终位阶段无时序约束告警，无多驱动/异常时钟 DRC；全工程 lint 的既有告警仍按 OPEN 保留，不能声称全工程零告警。

实际全顶层边界模型测试：两次复位释放、watchdog=625000、CMD0 超时事件、reader R1=FF，以及越过阈值仍能启动均 PASS。另有标签流模型验证 307200 像素、1801 扇区和 SDRAM 全字一致性。**这些均不是物理板证据。**

## 7. F6 未完成实验：只增加可观测性

工作区：
`D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/experiments/full_observe_F6/`

生成脚本：
[prepare_f6_probe.py](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/scripts/prepare_f6_probe.py)。已执行过，工作区存在，脚本会拒绝覆盖，不要重复执行。

相对 F5，仅修改 `v9_udp_m6_master_top.v` 与 `v9_m6_hdmi.v`：新增只读状态接线和独立 BASE50 计数器、修改诊断页及 d0=05475。**加载器、SPI、SDRAM、CRC、W2/S2 等全部逐文件字节一致**；F5 的 `>=` 启动条件继续保留，不含新功能修复。

预定 F6 页定义（与 F5 不同）：

| 页 | 含义 |
|---|---|
| d0 | 05475 |
| d1 | 原加载状态标志 |
| d2 | watchdog[28:16]，不再是故障码 |
| d3 | watchdog[15:0] |
| d4 | SDRAM 引擎 debug_count[14:0] |
| d5 | bit15=eng_init；bits14:10=引擎快照态；bits9:6=加载器实时态；bit5=ctrl_rst_n；bit4=全局 rst；bits3:0=loader_release[3:0] |
| d6 | 独立 debug_base_cycles[31:16]，仅按键复位，不依赖 PLL reset；运行时约每秒增加 763，约 86 秒回绕 |
| d7 | FF00 固定标记 |

d5 的引擎态来自原有 snapshot，加载器实时态和释放位直接接线；ERROR 后 snapshot 冻结这一语义没有改变。观测释放输出可以发现其逻辑状态，**仍不能保证所有物理复制节点同步健康**。

已完成：W2 strict lint PASS、全应用 top lint 无错误（既有警告 OPEN）；`sim/f6_observe/run.log` 中两次 `F6_RESET_PASS` 与 `F6_LATE_START_PASS`。未完成：TD 综合、布局布线、面积/时序门禁、ROM/CDC 最终核验、出位、上板。

中止的 TD 标签为 `synth_f6_logic`；`RESULT.json` 为 HOLD、complete=false、资源/时序为空、NOT_GENERATED。这是**用户要求停止后的中间结果**，不应解释成已测得资源超限或工具失败。原生中间日志已保留。没有可烧录的 F6 bit。

## 8. 建议接手顺序（尚未执行）

1. 先确认板上仍是 F5/05474；保留当前故障观察。不要先换卡、改 MISO 或改协议。
2. 如继续 F6，直接使用现有工作区，给中止的综合另起唯一标签，例如 `synth_f6_resume`，不覆盖 `synth_f6_logic`。先完成完整实现门禁，再交付探针位。
3. F6 上板后复位约 1 秒，放开等 12 秒；读取 d0～d7，隔约 2 秒复读 d2/d3/d4/d5/d6，先确认独立 BASE50 心跳与加载器释放位，再判断两个计数器是否推进。不要把所有变化过快的数值都强求精确读出，保留“变化/固定”观察。
4. 若独立心跳推进但加载器释放位不为 F，集中核查复位释放与物理复制节点；若释放位 F 而 watchdog/SDRAM 计数固定，集中核查这些寄存器的实际时钟、使能、复位及物理功能实现。若计数推进，按实际进入的 SD/加载态继续局部观测。以上均是分支建议，**尚无根因结论**。
5. 若探针仍出现 RTL 不可能状态，优先寻求物理网表/配置读取、片内逻辑观测或厂家实现工具支持。不要继续只靠改延时、改阈值碰运气，也不要将静态 STA 通过视为物理功能证明。
6. 恢复线稿后才做 ≥10 分钟、复位复现和完整动态验收，最后补齐必备归档。

## 9. 已实测可用的 TD 流程与注意事项

每个实验自带 `scripts/run_round2.ps1` 及配套脚本。原生工具 `D:/AnLu/bin/td_commands_prompt.exe`；策略固定采用 **LogicLevelOptimize**。默认映射此前面积/时序收敛困难，不建议重新扫种子/默认策略。

推荐次序：synth → check（标签 `check_f2`，供门级基准查询）→ place（seed2）→ 每阶段物理 SDC 精确重映射 → route（high，线程1）→ 必要时 hold clock → hold pad16 → CDC/ROM 核验 → bit。

- 路由如出现局部冲突，F3/F4 的 `RouteStrategy repair`、high/线程16曾成功；只在失败证据需要时使用，不要并行重复全量构建。
- 每次 place/route/hold 后，用该实验 `remap_physical_sdc.py` 更新实际物理端点，下一阶段才可使用；禁止用门级别名直接套物理结果。
- `audit_round2_cdc.py`、`audit_round2_rom.cjs` 是门禁工具；不是要求额外独立审查。
- 当前已出 F1～F5 最终位都保留 **MISO PAD INDELMUX=FIXDEL、INDEL=16**；RTL 四级缓冲已删除。不要误称最终物理 MISO 完全无延迟，也不能据现象宣告该 PAD 延迟为根因。
- `phys_opt` 在此 EG4 流程不支持；不存在已验证的 native fix_setup 捷径。
- Python 文本读写显式 UTF-8，WSL `.sh` 写 LF。`sources.f` 应逐行确认引用当前实验目录；旧实验的 lint 路径问题已修复并重新验证，不能照搬错误路径。
- 输出只提取 RESULT 关键字段，避免倾倒数千条中间约束告警；所有依赖动作先检查上一阶段结果。
- 不自动烧录、不修改 BURN_INDEX；只交明确 SHA 的主板位供用户操作。

## 10. 位文件定位与恢复基准

以下文件均在：
`D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/deliverables/`

| 用途 | 文件名 | SHA256 |
|---|---|---|
| 完整加载已验基准 L1 | M6_FDI_L1_20261006_0AF5C5AF.bit | 0af5c5af95c297bd016e7583b3c7db2a501d93fb2b5525d95fe1ba28c1a21d30 |
| SDRAM 已验 M1R | M6_FDI_M1R_20261006_685BC8D3.bit | 685bc8d3f94658f30817e5696930cf9bbfd69506cbdcdbaaea4719f44d4f95ce |
| TF 首扇区已验 TF1 | M6_FDI_TF1_20261006_9345F2B7.bit | 9345f2b77237f0a42ac1676bae3822f739455795afae94e847c3e057c8c46203 |
| 时钟彩条 S1 | M6_FDI_S1_20261006_4BA41B2F.bit | 4ba41b2fce390c31eea5cd1f8eb19332e56db424f3c751f682150ba8053f2a6d |
| F1 失败探针 | M6_FDI_F1_20261006_185FB6E2.bit | 185fb6e26e9d8212c80ef174a2121c00f0d10d418a0d419e100cde227b136016 |
| F2 失败探针 | M6_FDI_F2_20261007_EA0DB254.bit | ea0db254449e6c4122cd1e9f8b9dbb7236310431fa05789f62b2d5c9590a4388 |
| F3 失败探针 | M6_FDI_F3_20261007_C19139E1.bit | c19139e1b74d327e5542b70aa28272ef91425e4aff2402b1cc7cf7a65718adb7 |
| F4 失败探针 | M6_FDI_F4_20261007_C53C03B6.bit | c53c03b6e39d5cf119992a6a8612a64c4e918925687fb24cebd1c503e59af69c |

恢复/对比 L1 的工作区：
`D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/experiments/label_debug_L1/`

L1 top 为 `project/src/rtl/fdi_sdram_selftest_top.v`，store 使用 BASE50 + 单独两拍释放；其它彩条/自检使用网络 PLL C1，C3 提供 SDRAM 50MHz/180°。全显示 F1～F5 的 C1 输出不再接控制时钟，控制使用 BASE50；F4/F5 加载器是独立四拍释放。这些是对照差异，不是已证明病根。

原第四步主板显示基座（只读）：
`D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/iccoder_workspace/tasks/task_052_ethernet_pcm_link/td_run/v9_display_20261004_final2/eth_udp_m6_master_top.bit`

SHA256：`75959e68b425de7a36ee937949c683b956d90164ea72c68e2bbcd40b6d5d5d1b`（此前记录，本次未重新哈希该上游文件）。

**交接状态：当前真板仍失败；最后可重现的完整加载基准是 L1；F6 仅为已经准备好的只读探针源码，待接手者决定恢复构建。**
