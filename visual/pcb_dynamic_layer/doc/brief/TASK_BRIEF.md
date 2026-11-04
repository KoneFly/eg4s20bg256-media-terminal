# TASK_BRIEF — pcb_dynamic_layer W2 多周期版

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 授权依据：用户批准“W1 整体出列 + W2 多周期化重构”。V2 原版与证据见 archive/v2。

本轮范围仅为 W2 每帧状态更新、T1/T2 发布、独立验证及 TD 测量。W1 的 RTL、验证脚本和黄金用例已从活动目录出列；V2 全包归档已逐文件校验。停止继续投入现有行桶架构；解析式绘制留作二期候选，不实施。保留 W2 产生的音柱 H/Peak/peakHold、走线/脉冲、节点/元件、节拍和环上彗星状态；外侧弹射粒子继续删除。

V2 长组合链通过寄存器和真实多拍状态分解处理；同构算术共用少量运算资源。时间预算充裕，允许更新拍数增加，如实登记。保留串行 16bit 集中 bank，正式写口形状及位级黄金判据不变。

| 当前 W2 门禁 | 口径 |
|---|---|
| Setup/Hold | 50MHz 综合级零违例；不放宽 V2 时钟、I/O delay、uncertainty 或异步入口范围 |
| LUT 最小通过线 | TD Utilization Statistics #lut≤4500 |
| LUT 优化目标 | #lut≤4000 |
| DSP | ≤2 |
| 控制帧时间 | ≤833333 拍，登记实际最大值 |
| 黄金 | no_particles_v2 原始向量、模型及 packState 口径 |
| 协议 | T1 512 写→T2 140 写→DRAIN→单次 commit/done，ack 前不接新帧 |

按已实测数字判定，不缩减剩余状态、柱数、脉冲槽数或修改黄金。资源与综合级时序通过只表示当前独立门禁通过；配置矩阵未执行项及 RAM primitive 等价边界分别登记。

本轮交 W2 多周期 RTL 与独立面积/时序证据，供规格方核定落点。不修改 prototype/spec/task_045/主线，不定板、不集成、不生成 bit 或 FINAL_ACCEPTANCE.md。当前报告为 doc/output/W2_MULTICYCLE_REPORT.md；V2 历史报告在 archive/v2/doc/output。
