# START_PROMPT — pcb_dynamic_layer V2

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 授权依据：用户本轮批准的“规格变更 V2 + 重构授权”。V1 历史资料见 archive/v1。

当前任务按用户批准的 V2 执行；本目录四份 V2 brief 覆盖 archive/v1 与任务根旧 START_PROMPT 的粒子要求。上游仍只读，不更改 TASK_KICKOFF。此前批准的本任务 Verilator 离线例外继续有效。

先读 TASK_BRIEF.md、INTERFACE_SPEC.md、VERIFICATION_CONTRACT.md，再读 reference/profiles.cjs 和上游原模型/布局、task_045 packState。V2 配置档为 no_particles_v2。

本轮流程：删粒子并保持 T1/T2 → 路径③统一 2048×16 状态 bank → W1 仅柱顶连线 → 独立 lint/必要黄金对拍 → 分别 TD 综合级面积与时序 → 交测量报告。SDK RAM 仅使用公开原语接口，不复制厂商模型源码。资源目标 W2 3000、W1 1200 LUT，各 ≤2 DSP。

黄金：node "sim/gen_w2_tb_vectors.cjs"；node "sim/gen_w1_tb_vectors.cjs"。WSL：PROFILE=full bash "sim/run.sh"；bash "sim/run_w1.sh"。独立 TD 在 td_run/v2/w2 与 td_run/v2/w1 各自运行 run.tcl，避免共享中间文件。日志完成标记 V2_TD_COMPLETE、零 ERROR 必须同时满足，不能只凭 TD 进程退出 0。

只交独立测量，不定板、不集成、不产 bit、不生成 FINAL_ACCEPTANCE.md。真实数字、超标和未执行项汇总到 doc/output/V2_MEASUREMENT_REPORT.md。
