# TASK_BRIEF — pcb_dynamic_layer V2

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 授权依据：用户本轮批准的“规格变更 V2 + 重构授权”。V1 历史资料见 archive/v1。

本轮交付是 V2 两模块独立 TD 测量及对应源码、黄金与证据链，供规格方结合板卡余量核定落点。不定板、不集成、不生成烧录 bit 或 FINAL_ACCEPTANCE.md。

V2 删除圆周外侧弹射粒子的触发/LFSR、速度/切向抖动、动力学、寿命/回收、8 点历史、P bank/读写接口以及 W1 粒子轨迹/头部十字。保留 §3.2~3.6、音柱 H/Peak/peakHold、127 柱顶连线与 §3.8 环上彗星。原粒子发射 cooldown 不再影响保留音柱状态。上游 prototype/spec/task_045 只读。

批准路径③：串行 16bit 状态存储、集中地址规划。目标以 TD 实测为准，不为达到数字改变 T1/T2 字序、脉冲、彗星或剩余画面语义。

| 门禁 | W2 | W1 |
|---|---:|---:|
| LUT 等效占用 #lut | ≤3000 | ≤1200 |
| DSP | ≤2 | ≤2 |
| 时钟 | 50MHz | 25.2MHz |

W1 正式行池保持 6144×24bit，目标 ≤6 ERAM32K；辅助工作存储另报。P bank 为零且不进入总资源。显示为 640×480，D=647，3px 线宽。资源/时序不达标时报告真实数字，不降档；本轮测量交付不等于预算或板级验收通过。结果唯一登记于 doc/output/V2_MEASUREMENT_REPORT.md 及 sim/td_result_v2.json。
