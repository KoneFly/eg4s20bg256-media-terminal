# pcb_dynamic_layer W2 检查报告

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 当前范围：W2 多周期版；W1 已归档出列。

结论：本轮独立最小硬门禁通过；4000 LUT 优化目标未达。完整配置矩阵及板级验收未完成。

| 检查 | 结论 | 当前证据 |
|---|---|---|
| W1 整体出列，V2 归档校验 | COMPLETE | archive/v2/archive_manifest.json；当前 RTL/TB/运行/黄金仅 W2 |
| no_particles_v2 原始基线 | UNCHANGED | 原向量/manifest/模型配置档/打包器与 V2 归档 SHA 相同 |
| 默认真实 T1/T2 逐写口对拍 | PASS | 原 8 场景×300 帧，sim/sim_result_mc.json |
| 接受后频谱扰动、完整写序、单次 commit/done、ack 2FF | PASS | tb/tb_w2.cpp 与原始场景日志 |
| busy/未 ack 额外 tick、更新中/T2 发布中复位重入 | PASS | 另各 300 帧，总默认/协议 3000 帧 |
| 七组配置补充 | PASS | 最小/最大/全 0/全 65535/同 tick/busy 修改/退役地址，另 2100 帧 |
| 保留配置逐参数完整边界矩阵 | NOT_RUN | 组合极值补充不代替每个参数的全部矩阵 |
| Verilator lint | PASS | --Wall -Wno-BLKSEQ，无 WIDTH 或其他实质告警 |
| 故意生长移位变异 | KILLED | 编译成功后 T1 数据失配，sim/mutation_result_mc.json |
| 50MHz 综合级 Setup/Hold | PASS_SYNTHESIZED | 两项违例端点均 0，原 clock.sdc 未修改 |
| LUT 最小上限 / 优化目标 | PASS / NOT_MET | 数字唯一登记于 W2_MULTICYCLE_REPORT.md |
| DSP 与 RAM | MEASURED | 独立 TD area.txt，未计入已出列 W1 |
| 更新拍数 | PASS（已测范围） | 全部已测最高 19703 <833333 |
| 10 个受保护上游 SHA | UNCHANGED | sim/td_result_mc.json protected_sources |
| TD 通用未驱动/忽略 RAM 初值告警 | OPEN | 最终 run.log；运行时初始化有行为仿真覆盖 |
| TD primitive gate 等价 | NOT_RUN | 行为 RAM 不替代 gate 仿真 |
| 定板/S2 集成/布局布线/上板 | NOT_RUN | 本轮用户限定独立测量 |

TB 无内部状态后门，黄金只读模型；配置补充在隔离 VM 绑定参数，不改原模型或基线文件。5100 帧实际对拍均零失配，实际编译输入与当前源码、TD 输入三方 SHA 一致。

源码/黄金/报告链由 node "sim/archive_mc_result.cjs" "trial4" 重新核对；缺失、来源变化或未完整执行将报错。V2 检查报告保留在 archive/v2/doc/output，不计入当前 W2 PASS。没有提交、分支、bit 或 FINAL_ACCEPTANCE.md。
