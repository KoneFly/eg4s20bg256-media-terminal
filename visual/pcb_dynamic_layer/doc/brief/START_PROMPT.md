# START_PROMPT — pcb_dynamic_layer W2 多周期版

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 授权依据：用户批准“W1 整体出列 + W2 多周期化重构”。V2 原版与证据见 archive/v2。

本包当前只交付 W2。用户的最新授权覆盖 V2 关于 W1 的范围和旧 LUT 预算；本目录四份 brief 为当前执行口径。W1 已停止投入，解析式绘制仅列为二期候选，不在本轮开发。V2 源码、黄金、验证和 TD 证据归档保留，不能将归档用例计入当前 W2 门禁。

先读 TASK_BRIEF.md、INTERFACE_SPEC.md、VERIFICATION_CONTRACT.md，再读只读上游、reference/profiles.cjs、当前 W2 RTL/TB。黄金 no_particles_v2 与原二进制保持不变，不读取 DUT 生成期望。

本轮执行真实多拍状态机/寄存器切分、算术复用与适当位宽收敛，不使用放宽 SDC 或 multicycle_path 掩盖组合链。硬门禁：50MHz 综合级 Setup/Hold 零违例，TD #lut≤4500、DSP≤2；争取 #lut≤4000。T1 512 写、T2 140 写序、最后 T2 排空后 commit/done、2FF ack 与频谱/配置锁存保持冻结。更新拍数如实报告，预算 833333 拍/帧。

黄金在 sim/vectors/v2/w2。WSL 执行 PROFILE=full bash "sim/run.sh"、bash "sim/run_cfg.sh" 和 bash "sim/run_mutation.sh"；配置补充由 node "sim/gen_cfg_tb_vectors.cjs" 生成，不改默认基线。沿用已批准 Verilator 离线例外、Wall 与局部 BLKSEQ 风格例外，禁止 iverilog 或关闭位宽告警。只读上游不能修改。

TD 工程由 sim/prepare_td_w2.ps1 在 td_run/w2_mc 中创建不可覆盖的修订目录，各自沿用 V2 原始 clock.sdc。完整日志标记 W2_MC_TD_COMPLETE 与零 ERROR 必须同时满足，不只凭退出码。交付入口为 doc/output/W2_MULTICYCLE_REPORT.md 和 sim/td_result_mc.json。

仍不定板、不集成、不产 bit、不生成 FINAL_ACCEPTANCE.md；落点由规格方结合真实数字核定。
