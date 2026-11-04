# pcb_dynamic_layer V2 独立测量交付

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 授权：用户批准的“规格变更 V2 + 重构授权”，并确认同时包含 W1、W2。  
> 结论：两模块独立测量完成；两项 LUT 门禁失败，W2 综合级 setup 失败。此包不是功能全矩阵或板级验收。

## 1. TD 实测数字与口径

最终证据来自 `td_run/v2/w2/`、`td_run/v2/w1/` 各自的 `run.log`、`area.txt`、`timing.txt`、`resource.qor`。两个工程顺序运行，各自使用归档源码和独立工作目录；日志均有 `V2_TD_COMPLETE`，零 ERROR。结构化登记为 `sim/td_result_v2.json`，每个工程的 `source_manifest.json` 绑定源码、时钟约束、Tcl 和报告 SHA256。

工具为 Tang Dynasty V6.2.168116，测量器件 EG4S20BG256。执行至 `optimize_gate`、`update_timing`，未执行布局布线。两份时序报告的 Confidence 均为 **Synthesized**，STA coverage 均为 100%。器件仅用于独立逻辑测量，本轮没有核定落点。

| 模块 | LUT `#lut` / 上限 | REG `#reg` | DSP / 上限 | ERAM9K | ERAM32K | Setup WNS (ns) | Hold WNS (ns) |
|---|---:|---:|---:|---:|---:|---:|---:|
| W2 `pcb_frame_updater` | **5121 / 3000：FAIL** | 1482 | 1 / 2：PASS | 0 | 1 | **−27.956：FAIL** | +0.621 |
| W1 `pcb_particle_overlay` | **5816 / 1200：FAIL** | 764 | 1 / 2：PASS | **34** | **6** | +21.004 | +0.421 |

预算采用 TD Utilization Statistics 的 `#lut`，不以不同宽度 LUT 实例数替代。W2 `#Total_luts=3567`，W1 `#Total_luts=2316`，仅作为补充指标。上述 REG 采用 `#reg`，不与包含 I/O 寄存器的层次表 seq 混用。

| 综合级时序补充 | W2 | W1 |
|---|---:|---:|
| 约束频率 | 50MHz | 25.2MHz |
| 约束周期 | 20.000ns | 39.683ns |
| TD 报告最小周期 / Fmax | 47.956ns / 20.852MHz | 18.679ns / 53.536MHz |
| Setup TNS / 违例端点 | −1263.859ns / 205 | 0ns / 0 |
| Hold TNS / 违例端点 | 0ns / 0 | 0ns / 0 |
| Setup uncertainty | 1ns | 2ns |
| Hold uncertainty | 0.05ns | 0.05ns |

W2 最差路径为 `state_reg[5]` 到 `bus_wdata_reg[15]`，数据延迟 46.840ns、41 级逻辑（20 个 ADDER）。这是已测得的关键路径，不承诺进一步修改的确定收益。W1 的正 slack 仅证明当前综合级约束下的结果，不能代表布线后或板级时序通过。

W2 测量顶层有 1105 个内部接口 pad，超过器件 188 个 pad；其宽频谱接口没有通过裁位或改正式端口隐藏。该顶层用于逻辑面积/综合级 STA，不能直接用于物理工程。W1 pad 为 90，也未进入板级布局布线。

## 2. 删除粒子与路径③的实际实现

W2 已删除弹射粒子的发射判断、切向抖动、速度/Q4 积分、寿命/回收、8 点历史、LFSR 触发、粒子槽状态、P bank 与 P 写序。W1 删除粒子轨迹和头部十字，只处理 127 条相邻柱顶连线；保留模块名称，以减少不必要的接口迁移。两模块的 P 正式端口同步移除。

保留音柱 H/Peak/peakHold、T1/T2 打包、3 槽走线脉冲、节点/元件、生长/flow、节拍与环上彗星。峰值帽由既有 S2 按保留的 T2 字段绘制；本轮没有修改或集成 S2。

W2 集中为一个同步 `2048×16bit` bank，运行时初始化：

| 状态 | 16bit 字地址 |
|---|---|
| trace，128×8 字 | 0..1023 |
| startF，128×1 字 | 1024..1151 |
| node，128×2 字 | 1152..1407 |
| bar H/Peak/Hold，128×2 字 | 1408..1663 |
| previous spectrum，64×1 字 | 1664..1727 |

对外仍按 T1 512 写、T2 140 写发布，最后 T2 写完成后 DRAIN 再 commit/done，共 652 写；没有 P 写口。共享注册乘法单元与串行除法保留既有取整规则。TD 实测该状态 bank 占 1 个 ERAM32K。

W1 在输入无效期构建和归并有序区间，再发布冻结格式 `6144×24bit` 行池。正式记录仍为 x0/length_minus_one/luma，无 next 指针，长区间按最多 64px 分段；活动像素只消费同步读口预取 FIFO。行池占 6 个 ERAM32K，**全模块另有 34 个 ERAM9K**，用于构建区、行表、缓存和延迟等辅助存储。粒子 P 存储为零，不计入任一模块。

状态存储、几何、参考生成与实际对拍分别承担单一职责；复用统一词口和算术资源，避免重复状态 bank。重构没有缩减柱数、脉冲槽数、线宽、分辨率或修改黄金来适配资源结果。

## 3. V2 黄金与已执行验证

当前基线配置档为 `no_particles_v2`。`reference/profiles.cjs` 在任务内载入只读原模型，按唯一匹配校验移除已批准粒子调用；原模型文件未修改。`particles_v1` 仅保留作历史复现，粒子相关用例退出 V2 矩阵。历史实现和文档保存在 `archive/v1/`。

原模型 SHA256：`fbb2298fc26cef6f3e951c03bdc4857eee769209e57ce9e547a711d9996cf351`。默认 2400 帧同时比较原模型与无粒子配置档的 T1/T2，零失配；这证明在已测默认序列下，删除粒子没有影响保留状态。生成器/打包器/配置档/向量 SHA 见两份 `sim/vectors/v2/*/manifest.json`。

| 检查 | 已执行结论 | 原始/结构化证据 |
|---|---|---|
| W1/W2 lint | PASS；`--Wall -Wno-BLKSEQ`，未关闭位宽告警 | `sim/logs/v2/w1_lint.log`、`w2_lint.log` |
| W2 默认 T1/T2 真实写口 | 8 场景×300 帧，零失配 | `sim/sim_result_v2.json`、场景日志 |
| W2 接受后频谱扰动、完整写序、单次 commit/done、2FF ack | PASS | 同一独立 TB 与场景日志 |
| W2 busy/未 ack 重复 tick；更新中/T2 发布中复位重入 | 各 300 帧 PASS；总对拍 3000 帧 | `tick_overrun.log`、`reset_reentry.log` |
| W1 完整帧 hit/RGB565/alpha | 8 帧共 2,457,600 像素，零失配 | `sim/w1_result_v2.json`、`sim/logs/v2/w1.log` |
| W1 自然时钟 D=647、SOF/EOL、7 拍气泡、已完成快照间切换 | PASS，限当前 TB 范围 | 同上；TB 先等待行池发布完成 |
| 故意生长移位错误 `>>>8`→`>>>7` | KILLED，mutant 编译成功、TB 数据失配退出 1 | `sim/mutation_result_v2.json`、mutation 日志 |
| 10 个受保护上游文件 SHA | UNCHANGED | `sim/td_result_v2.json` protected_sources |

W2 已测默认序列最高更新耗时 16257 控制拍，即按 50MHz 名义频率计算 0.32514ms。该换算不表示当前失败的 W2 setup 已实现 50MHz。

W1 每次预取返回 ack 的实测耗时均为 198 像素拍。以下 build_cycles 从提交到完整发布，**包含预取**：

| W1 场景 | 构建总拍数 | 36000 拍消隐期限 |
|---|---:|---|
| all_empty | 4007 | PASS |
| bar_step | 21665 | PASS |
| bar_triangle | 19565 | PASS |
| bar_saturate | 20522 | PASS |
| bar_alternating | **55273** | **FAIL** |
| bar_random | 28019 | PASS |
| alpha_zero / alpha_partial | 各 20522 | PASS |

交替 0/255 柱高需要 55273 拍（25.2MHz 下约 2.19337ms），超过 36000 拍（约 1.42857ms）。最大观察行记录数 2437，正常用例 overflow 为零。**像素等价 PASS 与构建期限 FAIL 分别登记**，不能用前者掩盖后者。

## 4. 告警及未验证边界

W2 最终 TD 告警：`SYN-5025` 1 次、`SYN-6562` 1 次。前者为未驱动引脚/网络按零处理的通用告警，后者为 RAM 初值被 `eram_init=off` 忽略；运行时初始化已在 Verilator 覆盖，但未进行 gate 仿真。

W1 最终 TD 告警：`HDL-5001` 1 次、`SYN-5025` 2 次、`SYN-5011` 6 次、`SYN-6562` 6 次。`SYN-5011` 对应 `pool/bank[0..2]$high/mem` 的 `bea[0]/beb[0]`；源码明确绑常量，但最终映射仍报告未驱动。告警状态为 **OPEN**，不称为已消除或继承通过。完整行与计数保存在 `sim/td_result_v2.json`。

`pcb_ram_2k16.v` 的 Verilator 分支是同步一拍行为 RAM，TD 分支使用公开 `EG_LOGIC_BRAM` 接口及 `IMPLEMENT="32K"`。没有复制厂商模型源码，也没有 gate RAM 仿真证明两分支完全等价；尤其 W1 byte-enable 告警仍是后续接收风险。

W1 使用单个活动行池，TB 只在完整发布后开始有效帧。若有效像素在发布中途开始，尚未证明行池切换原子性；构建在活动输入期暂停，也不能据此宣称任意短消隐下连续更新已满足冻结语义。当前样本与已测结果不作为 60Hz 连续更新验收。

以下保持 **NOT_RUN**：保留配置最小/最大/越界及帧边界完整矩阵、故意桶溢出注入、发布中途进入有效帧、TD primitive gate 仿真、S2 联合 smoke、布局布线及上板。没有生成 bit 或 `FINAL_ACCEPTANCE.md`。预算和构建期限的失败不通过降档、减少冻结项或改参考判据处理；本轮交付停在用户指定的独立测量范围。

## 5. 复核入口

实际执行方式见 `run_report.md`。只重建归档、不重跑 TD：在任务根执行 `node "sim/archive_v2_result.cjs"`。脚本校验当前 RTL、实际仿真编译输入、黄金、TD 归档输入和只读上游 SHA 后，登记真实失败门禁。

最终数字只以本报告、`sim/td_result_v2.json` 及 `td_run/v2/` 原始报告为当前依据。`td_run/*_v2_gate.*` 是前期中间记录，V1 `sim/td_result.json` / rev2 属历史资料，不能替代当前 V2 独立测量。
