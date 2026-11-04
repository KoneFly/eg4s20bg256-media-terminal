# pcb_dynamic_layer 检查报告

> 日期：2026-10-04  
> 总结论：资源门禁失败，任务未完成；以下 PASS 仅指对应已执行检查。

| 检查 | 状态 | 独立证据 |
|---|---|---|
| T1/T2 默认打包与 task_045 packState 一致 | PASS | startup_audit_rev1：1800 帧模型审计 |
| P x11/y10 极值、LE 12 字和高保留位 | PASS（黄金） | startup_audit_rev1；不是 DUT 极值注入 |
| 6144×24bit 行记录解包恢复逐像素 luma | PASS（黄金） | 17 帧回环；最大观察 4900 条 |
| W2 Verilator lint | PASS | Wall，仅关闭 BLKSEQ 风格告警 |
| W2 8 类刺激共 2400 帧真实写口 | PASS | sim/sim_result.json，逐帧 T1/T2/P 零失配 |
| 接受后频谱扰动、写序、提交单次、等待 ack | PASS | 相同 TB 与原始日志 |
| busy/未 ack 的额外 tick | PASS | tick_overrun：300 帧回归 |
| 更新期间/P 序列化期间复位后重新播放 | PASS | reset_reentry：300 帧回归 |
| 故意生长移位错误 | KILLED | mutation_result.json，第 26 帧 T1 失配 |
| 运行时配置最小/最大/越界及帧锁存 | NOT_RUN | cfg_boundary 尚无完整独立参数化黄金 |
| W1、647 拍延迟、S2 合体 smoke | NOT_RUN | 资源门禁暂停 |
| TD W2 LUT | FAIL | 6646 > 2500 |
| TD W2 DSP | PASS | 1 ≤ 2 |
| TD W2 内部 RAM | MEASURED | 26×ERAM9K；外部 P bank 不在本顶层 |
| TD byte-enable/RAM 告警 | OPEN | 见 run_report；未证明 gate RAM 无差异 |
| Setup/Hold WNS、物理布线、上板 | NOT_RUN | 宽内部接口的面积顶层不可代替板级工程 |

默认完整回归为 boot_silence、boot_low、play_low、play_mid、play_high、saturate、impulse_broadcast、silence_decay 各 300 帧。overrun/reset 另各 300 帧，合计实际对拍 3000 帧。最高更新耗时 22757 拍，相比 833333 拍控制域预算有余量；不能外推为所有配置和未来 W1 的帧时序结论。

当前 DUT SHA256：`f2baa756322e81aa4ffc7877ef88ee45b2aad37397e2c7e74d889e4ff25e1806`。sim_result 包含实际编译源码/TB、每场景向量 SHA；TD 对同一 RTL 使用 rev2 归档。只读上游 SHA 再次独立核对并记录在 td_result。旧 P0 报告保留为启动审计证据，不替代本报告。

判据没有从 RTL 输出生成期望值：黄金运行只读 JavaScript 模型，TB 只读取二进制期望并检查正式写口；变异发生在 /tmp 的隔离副本中。未使用 RTL 内部状态后门，未修改 task_045、prototype、spec 或主线；没有提交、分支、FINAL_ACCEPTANCE.md 或板级 PASS。
