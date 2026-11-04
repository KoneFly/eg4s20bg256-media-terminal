# Handoff Packet — W2 多周期版

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 当前范围：W2 多周期版；W1 已归档出列。

仅交独立测量；没有 ChipWatcher 采集或板级集成。最小门禁与优化目标结论见 W2_MULTICYCLE_REPORT.md。

| 已实现信号 | 位宽 | 观察点 / 语义 |
|---|---:|---|
| frame_tick/frame_ready/frame_accept | 各 1 | 仅 ready 接受；当前帧锁存频谱及配置 |
| state | 7 | 多周期状态机，映射见 localparam |
| state_wr_en/sel/addr/lane/data | 1/1/8/2/32 | T1 512 写、T2 140 写 |
| state_commit_toggle/frame_done | 各 1 | 最后 T2 写排空后单次翻转/单拍 |
| ack_meta/ack_sync | 各 1 | 外部接收方 ack 的 2FF；等待期间不接帧 |
| ram_we/ram_addr/ram_wdata | 1/11/16 | 集中 bank 同步词口及运行时初始化 |
| trace_work/record_rdata | 128/32 | 共享 trace 读改写、node/bar 读缓冲 |
| spec_index/spec_value | 7/8 | 对象谱索引及独立注册的谱值 |
| mul_a/mul_b/mul_product | 11/9/20 | 共享 DSP，完整非负积 |
| rf_a/rf_b/rf_calc/rf_result | 9/9/9/8 | 共用减法器的分拍操作与结果 |
| bus_return/mul_return/rf_return | 各 7 | 共用步骤返回状态 |
| err_valid/err_code | 1/4 | 非 ready tick 的 sticky code=1 |

通过 TD Read Design 临时加探针，不在源码保留 MARK_DEBUG。建议按接受/锁存→算术步骤→内部 bank→T1/T2→commit→外部 ack 定位。探针建议不表示已采集过硬件波形，不替代独立正式口对拍。

W1 探针和接口整体退役，旧清单在 archive/v2/tb/handoff_packet.md。外部快照接收方尚未集成；保留正式 ack 输入，不能为独立运行而绑掉握手。
