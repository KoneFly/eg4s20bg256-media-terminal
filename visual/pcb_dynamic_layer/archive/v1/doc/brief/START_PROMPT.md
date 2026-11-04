# START_PROMPT — pcb_dynamic_layer

> 最后核对日期：2026-10-04  
> 维护者：视觉子系统负责人  
> 任务：M6 动态层合并包，包含 W1 `pcb_particle_overlay` 与 W2 `pcb_frame_updater`。

## 必读文档（按顺序）

1. `../../../../../iccoder_workspace/TASK_KICKOFF.md`（从本文件目录解析；任务纪律、仿真/上板门禁、文档归档规则）
2. `doc/brief/TASK_BRIEF.md`
3. `doc/brief/INTERFACE_SPEC.md`
4. `doc/brief/VERIFICATION_CONTRACT.md`
5. `reference/UPSTREAM_FACTS.md`
6. `visual_workspace/spec/M6_PCB_SKETCH.md`
7. `visual_workspace/spec/M6_PCB_PORTING_PLAN.md` §2.3、§3
8. `visual_workspace/INTERFACE_CONTRACT.md` §9
9. `iccoder_workspace/tasks/task_045_pcb_pixel_renderer/doc/brief/INTERFACE_SPEC.md` 与 `doc/output/behavior_spec.md`
10. `iccoder_workspace/tasks/task_045_pcb_pixel_renderer/reference/gen_vectors.cjs` 的 `packState()`

通用纪律以 `TASK_KICKOFF.md` 为准，不在本文件重复。所有上游参考文件只读，以源码和冻结契约为准，不要凭示例代码猜测端口或字序。

2026-10-04 用户确认本任务的 `doc/output/CONTRACT_CHANGE_PROPOSAL.md`。此独立任务允许上板前执行 WSL Ubuntu Verilator lint、P0/L0/L1、变异及连续全帧 smoke；不使用 iverilog，不以离线结果表述板级 PASS。只允许修订本任务契约和黄金，不修改上游。内部行记录为 6144×24bit，正式端口保持原声明。

## 模型选择建议

| 档位 | 建议 |
|---|---|
| 强推理档 | 推荐用于 W2 动力学翻译、T1/T2/P 打包和 W1 跨时钟快照调试 |
| 标准档 | 适用于接口已冻结后的单模块 RTL、TB 和脚本实现 |
| 探索档 | 适用于独立黄金脚本、资源/行分桶容量分析 |

## 上游依赖

- `prototype/pcb_model.js`：独立 JavaScript 动力学与覆盖层参考；只读，禁止将 RTL 反写回模型。
- `prototype/pcb_layout.js`：70 条走线、128 节点、18 元件和 128 柱静态几何；只读。
- `prototype/pcb_labels.js`：S2 标签编码背景；只读。
- `golden/pcb/obj_tables.json`：S1 烘焙对象表和调色/行表；只读。
- `task_045_pcb_pixel_renderer`：T1/T2 写入字段及 647 拍 S2 输出语义；不得修改其 RTL、端口或黄金。
- `task_055_selfmade_fft`：未来频谱前端；本任务只接收每帧 128 路频谱，不依赖 FFT 内部实现。

## 分阶段执行计划

### P0：接口与存储模型自检

- 按 `INTERFACE_SPEC.md` 创建 W2 T1/T2 写口、P 的 2048×16 串行写口、W1 P 的同步串行读口和音柱镜像缓存；
- TB 先检查 T1/T2/P 写序、toggle 交握和同步读一拍相位；
- 不改 S2 状态表字段，不把 P 粒子状态写入 T2 保留地址。

### P1：W2 基础动力学

- 先实现 8 段聚合、flux/onset、beatK/loOn；
- 再实现走线生长、flow、脉冲、节点、音柱和彗星；
- 最后实现粒子推进、历史点和 P 打包；
- 每个阶段都用独立黄金向量对拍，不使用 RTL 内部状态作为参考。

### P2：W1 快照与行分桶

- 完整同步 P 快照后，生成柱顶连线和粒子轨迹；
- 执行整数 Bresenham、3×3 最大值膨胀、行区段合并；
- 只在无效像素/帧间隙构建行区段，活动区每拍按扫描序输出。

### P3：输出对齐与合体 smoke

- 将 W1 输出固定到 D=647 拍；
- 验证 `in_sof/in_eol`、断流、帧尾和状态快照切换；
- 与 task_045 的 S2 输出做一帧合体对拍，但不修改 task_045。

### P4：验证与综合

- 先按 `VERIFICATION_CONTRACT.md` 跑 L0/L1；
- 再进行至少一处变异杀死；
- 独立 TD 综合，记录实际 ERAM32K/ERAM9K、LUT、REG、DSP、Setup/Hold WNS 和新增告警；
- 若资源超预算，暂停并报告，不擅自降低 `PART_N`、历史点数、分辨率或线宽。

## 工具调用方式

任务包正式立项后：

```text
仿真：在任务根执行 `bash sim/run.sh`，使用 `PROFILE=quick|full` 和 `SCEN_ONLY=<场景>`。
TD：在任务自己的 `td_run/` 中执行签发的 Tcl，不得自行改源文件树或调用路径。
```

任务包尚未提供可执行 `sim/run.sh` 和 `td_run/`，实现方必须先补齐脚本再声称验证完成。

## 交付前必须包含

- `rtl/pcb_frame_updater.v`
- `rtl/pcb_particle_overlay.v`
- TB、黄金脚本、状态向量和覆盖层向量；
- `doc/output/behavior_spec.md`、`check_report.md`、`run_report.md`、TD 报告；
- `tb/handoff_packet.md` 中的 ChipWatcher 探针清单；
- 不得创建 `FINAL_ACCEPTANCE.md`，该文件仅由验收方独立通过后生成。

## 不要做的事

1. 不得修改 task_045 或其 `reference/` 黄金；
2. 不得修改 `prototype/`、`spec/` 或主线 `m1a_top.v`；
3. 不得把加密 IP 源码复制到 `rtl/`；
4. 不得用 `pos_q4==0` 代替 `peak==0` 空槽判据；
5. 不得按 T2 花括号顺序猜字节序，必须遵循 `packState()`；
6. 不得在有效像素期间逐像素扫描所有 1024 条动态线段；
7. 不得在帧尾插入未经输入驱动的有效像素；
8. 不得把资源估算、仿真 PASS 或逻辑正确性表述为板级 PASS；
9. 不得在没有独立黄金证据时修改算法、默认参数、坐标位宽或状态字段。
