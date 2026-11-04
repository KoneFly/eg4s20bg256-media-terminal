# pcb_dynamic_layer W2 多周期版独立交付

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 授权：用户批准 W1 整体出列、W2 多周期化重构。  
> 结论：W2 最小硬门禁通过；4000 LUT 优化目标未达到。当前范围仅 W2，不定板、不集成。

## 1. 最终独立 TD 数字

当前 RTL 对应 `td_run/w2_mc/trial4/` 的独立 TD 工程。最终日志有 `W2_MC_TD_COMPLETE`、零 ERROR，进程退出 0。输入源码、SDC、Tcl、面积/时序/QoR 与日志已绑定 SHA；结构化登记为 `sim/td_result_mc.json`，原始来源为该工程 `area.txt`、`timing.txt` 和 `run.log`。

| 指标 | 最终实测 | 当前门禁 | 结论 |
|---|---:|---:|---|
| LUT 等效占用 `#lut` | **4492** | ≤4500 | **PASS，余量 8** |
| LUT 优化目标 | 4492 | ≤4000 | **NOT_MET，高出 492** |
| `#Total_luts` 实例数 | 3468 | 不替代 #lut 门禁 | 记录 |
| REG `#reg` | 1544 | 无单独上限 | 记录 |
| DSP | **1** | ≤2 | PASS |
| ERAM9K / ERAM32K | **0 / 1** | 如实报告 | 记录 |
| Setup WNS / TNS | **+2.909ns / 0ns** | 50MHz 零违例 | PASS_SYNTHESIZED |
| Hold WNS / TNS | **+0.621ns / 0ns** | 零违例 | PASS_SYNTHESIZED |
| Setup / Hold 违例端点 | **0 / 0** | 0 / 0 | PASS_SYNTHESIZED |
| STA coverage | 100% | 完整约束口径 | 记录 |
| 报告最小周期 / Fmax | 17.091ns / 58.510MHz | 综合级补充指标 | 记录 |

工具为 Tang Dynasty V6.2.168116，测量器件 EG4S20BG256。执行至 `optimize_gate` 和 `update_timing`，Confidence 为 **Synthesized**，Slow/Fast 两角检查；未布局布线。

`clock.sdc` 与归档 V2 原件逐字相同：20ns 时钟、setup uncertainty 1ns、hold uncertainty 0.05ns、原 I/O delay，false path 仅为外部异步 rst_n/snapshot_ack_toggle 入口。没有增加 multicycle_path、false_path 或放松约束来取得通过。

宽内部接口仍为 1105 个 pad，超过器件 188 个 pad。本工程用于逻辑面积及综合级 STA，未裁掉频谱位或改正式端口；不能从本结果声称物理工程或板级通过。8 LUT 的最小预算余量有限，4000 目标未实现，落点仍由规格方结合板上余量核定。

## 2. 多周期实现与冻结语义

V2 最差链为 46.840ns、41 级逻辑和 20 个 ADDER。此次通过实际寄存器与状态分步切断链路：

- 先登记对象谱索引，再独立注册 128:1 频谱选择结果，避免它与后续算术串联。
- 原 8bit 展开乘法与生长乘法统一复用一个 DSP；输入按非负取值范围保留 11/9bit，完整积保留 20bit，再显式扩成原有有符号语境。
- flow、节点亮度和柱高的 rise/fall 共享一个 9bit 减法器，分步计算差、目标减量及 fall 钳位。rise 用整数恒等式 `target-floor((target-current)/4)`，等价于原 `current+floor((3*delta+3)/4)`；fall 仍保持 flow/node 的减 2、bar 的减 3。
- 节拍最大值和彗星弱槽选择改为多拍扫描，保留严格比较和最早槽优先规则；节点、柱峰值和脉冲更新分步提交中间结果。
- trace 读入、修改、串行写回共用同一记录缓冲；node/bar 共享 32bit 读缓冲，避免重复宽记录暂存。
- 配置范围比较集中复用；各参数高位显式补零。频谱 flux 是 16 路正差之和，≤4080；平均值递推始终在旧平均与 flux 之间，因此用 12bit 保留完整可达数值，差用 13bit 有符号保存。
- 内部地址改为等价拼接，保留集中 bank 地址；平滑相位 ROM 由原 65 点及原分段线性取整预计算，不改变曲线。

仍使用一个 `2048×16bit` 同步状态 bank：trace 0..1023、startF 1024..1151、node 1152..1407、bar 1408..1663、prev 1664..1727。运行时初始化和全部保留状态继续存在，没有外侧粒子/P bank。

正式 W2 端口与 V2 逐字一致。每帧仍为 T1 512 写、T2 140 写，共 652 写；地址/lane/字段/字序、peak=0 空槽判据、最后 T2 写排空后的 DRAIN/commit/done、ack 2FF、频谱和配置锁存规则均保留。未缩减 128 音柱、三槽脉冲、四个环上彗星或修改黄金。

按状态更新、词 RAM、黄金、TB、证据归档拆分职责；复用运算单元与记录缓冲，集中规划地址。实现针对本轮门禁收敛，没有增加二期绘制或系统集成功能。

## 3. 黄金、实际仿真与拍数

`reference/profiles.cjs`、原 W2 生成器/打包器、`sim/vectors/v2/w2/manifest.json` 及八个基线二进制均与 V2 归档 SHA 相同。配置档仍为 **no_particles_v2**，10 个受保护上游文件独立 SHA 核对均 UNCHANGED。原模型 SHA 为 `fbb2298fc26cef6f3e951c03bdc4857eee769209e57ce9e547a711d9996cf351`。

最终实际编译核心 SHA 为 `49c189938efd8d0d02dc6db9aa764e8c77f06908da73dfc5c31eb7a77e2c3703`。`sim/w2_compile_manifest_mc.json` 和 `w2_cfg_compile_manifest_mc.json` 记录实际输入副本；收集结果再次与当前源码、TD 归档校验。TB 只检查正式口，不读写 DUT 内部状态。

Verilator 5.032、WSL Ubuntu；lint 为 `--Wall -Wno-BLKSEQ`，未屏蔽 WIDTH 或其他实质告警。最终 lint 无告警。原十组默认/协议用例各 300 帧，共 **3000 帧零失配**：

| 默认/协议场景 | 最大更新拍数 |
|---|---:|
| boot_silence | 17900 |
| boot_low / play_low | 各 18276 |
| play_mid | 18115 |
| play_high | 17988 |
| saturate / silence_decay | 各 17900 |
| impulse_broadcast | 18188 |
| tick_overrun / reset_reentry | 各 18276 |

原有完整写序、单次 commit/done、ack 等待、接受后现场频谱扰动、busy/未 ack 拒绝额外 tick、更新中/T2 发布中复位重入判据全部通过。默认最高 18276 拍，比 V2 16257 拍增加 2019 拍。

为验证共享配置限幅及锁存，额外从同一原模型在隔离 VM 中绑定参数生成七组补充刺激，**没有修改基线或上游文件**。七组各 300 帧，共 **2100 帧零失配**：

| 配置补充场景 | 判据 | 最大更新拍数 |
|---|---|---:|
| cfg_min | 八参数合法最小值 | 19703 |
| cfg_max | 八参数合法最大值 | 17756 |
| cfg_clamp_low | 八个原始输入均 0，按范围限幅 | 19703 |
| cfg_clamp_high | 八个原始输入均 65535，按范围限幅 | 17756 |
| cfg_same_tick | FLOW_V0 与首次 tick 同拍写入，当前帧用旧值、下帧用新值 | 18513 |
| cfg_during_busy | 接受后修改 FLOW_V0，当前帧锁存不受影响、下帧生效 | 18513 |
| cfg_retired_ignored | 8/9/10/11/12/63 写入不改变固定 W2 基线输出 | 18513 |

所有已测场景最高为 **19703 控制拍**，50MHz 名义周期下为 **0.39406ms**，占 833333 拍预算约 2.36%。这是已测场景最大值，不外推为全部可能频谱/配置的形式上界。

GROW_CAP 的隔离变异 `>>>8`→`>>>7` 编译成功；TB 在零起始 frame=25、cycle=434644 检出 T1 addr=0/lane=0 expected=3489660932、actual=3489660936，正常数据失配退出 1，状态 **KILLED**。正式 RTL 未修改。

## 4. W1 出列与历史证据

V2 的 351 个原文件已复制归档、逐个 SHA 校验，根入口另存；见 `archive/v2/archive_manifest.json` 与 README.md。W1 RTL、区段 RAM、TB、运行/收集/黄金脚本、八组黄金目录均已从活动实现出列。当前 lint、编译、TD 和验证矩阵仅含 W2，不将归档 W1 PASS 计入当前结果。

W1 的 5816 LUT、34×ERAM9K+6×ERAM32K、55273 拍构建等历史证据保留在 V2 归档。解析式绘制列为二期候选，当前没有继续实施。

四轮实际 TD 记录均保留，最终仅以 trial4 与当前源码绑定结果交付：

| 修订 | LUT | REG | Setup WNS (ns) | Hold WNS (ns) |
|---|---:|---:|---:|---:|
| V2 原版 | 5121 | 1482 | −27.956 | +0.621 |
| trial1：算术拆步与复用 | 4908 | 1864 | +2.682 | +0.621 |
| trial2：记录缓冲复用 | 4697 | 1592 | +5.193 | +0.621 |
| trial3：值域/配置收敛 | 4498 | 1544 | +2.413 | +0.621 |
| trial4：等价地址拼接 | **4492** | **1544** | **+2.909** | **+0.621** |

## 5. 告警及未执行边界

最终 TD 仅有 `SYN-5025` 1 次（未驱动引脚/网络按零处理的通用告警）和 `SYN-6562` 1 次（state_bank 初值被 eram_init=off 忽略）；没有 W1 byte-enable 路径或 W2 SYN-5011 告警。完整原始行见 run.log / td_result_mc.json，告警状态保留 OPEN，不称作无告警。

W2 bank 通过运行时初始化，Verilator 使用同步一拍行为 RAM；TD 使用公开 EG_LOGIC_BRAM 32K 接口。未执行 gate primitive 仿真，不能用行为 RAM PASS 证明厂商 primitive 完全等价。未执行每个参数逐一的完整边界/越界组合矩阵，七个组合补充用例按实际范围登记。

未定板、未 S2 集成、未布局布线、未上板；没有 bit 或 FINAL_ACCEPTANCE.md。当前最小门禁通过不等于系统最终验收。

## 6. 复核入口

实际命令与工具口径见 `run_report.md`。重新校验已有产物而不重跑 TD：在任务根执行 `node "sim/archive_mc_result.cjs" "trial4"`。源/黄金/报告不一致将报错；优化目标 NOT_MET 独立记录，不被硬门禁 PASS 覆盖。

最终数字以本报告、`sim/td_result_mc.json` 及 `td_run/w2_mc/trial4/` 原始产物为当前依据。V2 原结果在 `archive/v2/`，可用于核对历史变化。
