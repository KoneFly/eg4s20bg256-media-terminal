# Task Brief — pcb_dynamic_layer（M6 动态层）

> 最后核对日期：2026-10-04  
> 维护者：视觉子系统负责人  
> 状态：用户于 2026-10-04 确认本包契约修订，进入实现；修订依据见 doc/output/CONTRACT_CHANGE_PROPOSAL.md  
> 上游效果规格：`visual_workspace/spec/M6_PCB_SKETCH.md`

## Task Summary

在不修改已验收的 S2 `pcb_pixel_renderer`、不碰主线 `m1a_top.v` 的前提下，完成 M6 PCB 线稿频谱的两块动态层：

- **W1 `pcb_particle_overlay`**：读取音柱与粒子快照，按行分桶并按扫描序输出柱顶连线、粒子 8 点轨迹和粒子头部覆盖层；
- **W2 `pcb_frame_updater`**：每个视频帧接收 128 路 8bit 频谱，执行 `M6_PCB_SKETCH.md §3.2~§3.8` 的全整数动力学，并通过 S2 冻结写口发布 T1/T2 状态表及独立 P 粒子表。

## Scope

### 本任务包含

1. W2 的 128 路频谱帧锁存、8 段聚合、谱通量起音检测；
2. 走线生长、持续电流、3 槽起音脉冲、节点/片内低频表、音柱峰值帽、粒子推进、环上彗星；
3. W2 对 S2 T1/T2 状态表的完整快照写入；
4. W2 对 P 粒子状态表的快照写入（每粒子 12 个 16bit 字）；
5. W1 的音柱柱顶相邻连线与粒子历史轨迹逐行分桶；
6. W1 的 3×3 最大值膨胀语义、径向调色、RGB565 输出；
7. 与 S2 输出固定延迟对齐的覆盖层 `overlay_valid + overlay_rgb565`；
8. 独立 TB、黄金生成脚本、180 帧启动和播放段逐帧状态核对。

### 本任务不包含

- 不修改 `task_045_pcb_pixel_renderer` 的 RTL、端口、T1/T2 字段或黄金；
- 不实现 S4 频谱前端，不接 PCM/FFT；
- 不产生 HDMI/AXIS/HSYNC/VSYNC；
- 不修改 SDRAM、BMP 加载器、`async_pixel_fifo` 或 `m1a_top.v`；
- 不负责 S6 主线合成和上板集成；
- 不改变 `640×480@60Hz`、25.2MHz 像素时钟和既有帧缓存布局；
- 不把粒子状态硬塞进 S2 已冻结的 T1/T2 地址范围。

## 硬件约束（Hardware Constraints）

| 项 | 冻结约束 |
|---|---|
| 器件 | 安路 EG4S20BG256 / HX4S20C |
| 时钟 | W2 控制域 50MHz；W1 像素域 25.2MHz；不新增 PLL |
| 输出吞吐 | W1 在有效显示流中每拍消费一个像素，不允许回退、乱序或背压 |
| S2 写口 | `wr_en/wr_sel/wr_addr/wr_data/wr_lane` 逐拍写入，语义与 task_045 完全一致 |
| T1/T2 存储 | 由集成方提供真双口状态表；S2 读侧仍是原有 `st_trace/st_misc` 端口 |
| P 存储 | 逻辑 128 条记录×12 个 16bit 字；物理按 2048×16 显式落 1 个 ERAM32K，写口来自 W2、读口来自 W1 |
| W1 分桶缓存 | 只允许片上 ERAM/LUTRAM；不访问外部 SDRAM，不建立全屏帧缓存 |
| 算术 | 全整数；不使用浮点、实时三角函数、开方或任意除法；乘法优先移位/加法，必要乘法如实报告 DSP |
| 坐标 | 粒子历史点为有符号整数像素坐标：x 11bit、y 10bit；越界点保留，光栅化时裁剪 |
| 引脚 | 两个模块均不新增物理引脚约束 |
| 预算口径 | W2 目标 ≤2500 LUT、≤2 DSP；W1 目标 ≤2200 LUT、≤2 DSP；P bank 物理形状固定为 2048×16 的 1×ERAM32K，W1 行区段池逻辑容量为 6144×24bit，物理 ERAM 块数目标 ≤6；所有物理块数以 TD 实测为准，不以逻辑位数臆测 |

## IP复用评估

| 候选 | 属性 | 适用性 | 决策 |
|---|---|---|---|
| TD `RAM/ROM` | 明文/原语 | P 表、行分桶、调色 ROM | 选用；仅例化/推断，不复制厂商源码 |
| TD `Soft_FIFO` | 加密 | 本任务无背压 FIFO，且需确定性扫描序 | 不选 |
| TD `Divider` | 加密 | 动力学可由移位、查表和固定常数完成 | 不选 |
| TD `CORDIC` | 明文/原语 | 本任务只使用预存方向向量，不需要三角函数 | 不选 |
| TD `FFT` | 加密 | 属 S4/task_055，本任务只接收已生成的 128 路帧 | 不适用 |
| 自研定点逻辑 | 明文 | 状态机、包络、起音、粒子推进和行分桶 | 选用；便于 Verilator/独立黄金验证 |

已查阅 `docs/HARDWARE_TOOLCHAIN_REFERENCE.md`：本任务不引入加密 IP，不把任何 IP 源码复制到 `rtl/`。

## 调试与可观测性设计

不新增正式调试端口；建议 TD `Read Design` 后临时观察以下内部网络，交付源码不保留 `MARK_DEBUG`：

| 分支 | 探针 | 失败含义 |
|---|---|---|
| W2 未接收帧 | `frame_tick_seen`、`busy`、`err_overrun` | 帧节拍未到或更新器被堵塞 |
| W2 状态写错 | `state_phase[3:0]`、`wr_count[10:0]`、`state_epoch` | 写序列、T1/T2 打包或提交沿错误 |
| W2 粒子错 | `particle_index[6:0]`、`particle_active`、`particle_life` | 发射/回收/历史点移位错误 |
| W1 快照撕裂 | `prefetch_phase`、`snapshot_bank`、`state_epoch_seen` | 未完成预取就切换快照 |
| W1 分桶溢出 | `bucket_overflow_sticky`、`bucket_ref_count` | 行引用池不足或几何异常 |
| W1 无覆盖 | `overlay_hit`、`overlay_luma`、`overlay_valid` | 行分桶、裁剪、延迟对齐或颜色路径错误 |

### W2 sticky 错误码建议

- `4'h1`：帧节拍在 `busy` 时重复到达；
- `4'h2`：状态写计数未在预期范围内完成；
- `4'h3`：P 表写地址越界；
- `4'h4`：粒子坐标超出内部有符号表示范围；
- `4'h5`：状态提交沿与 P 表最后一次写不同步。

## 依赖

| 依赖 | 用途 | 约束 |
|---|---|---|
| `spec/M6_PCB_SKETCH.md` | 动力学和默认参数唯一来源 | 只读，不得改写算法语义 |
| `prototype/pcb_model.js` | W2 独立黄金状态模型 | 只读；模型改动须由规格方登记并重出黄金 |
| `prototype/pcb_layout.js` | 70 条走线、128 节点、18 元件、128 音柱的构建期表 | 只读；RTL 只接收生成的常量表 |
| `prototype/pcb_labels.js` | S2 标签编码背景 | 只读；W1 不修改标签图 |
| `golden/pcb/obj_tables.json` | 走线/音柱/调色/行区段静态表 | 只读；必要 ROM 由脚本再生成 |
| `task_045_pcb_pixel_renderer` | T1/T2 写口和 RGB565 色彩语义 | **不得修改接口**；字段打包以 `packState()` 为准 |
| `task_055_selfmade_fft` | 未来提供 128 路频谱帧 | 本任务不依赖其内部端口；仅冻结 `spec_frame + frame_tick` 语义 |

## 验收结果（目标）

1. W2 启动 180 帧、播放 120 帧场景，每帧 T1/T2/P dump 与独立黄金逐位相等；
2. W2 状态写序列完整：T1 512 次、T2 140 次、P 1536 次，且提交沿在最后一次写之后；
3. W1 128 柱顶连线、最多 128 粒子×7 条历史线段、粒子头部十字点均能逐像素生成；
4. W1 覆盖层输出保持扫描序，`overlay_valid` 与 S2 `pixel_valid` 具有固定 647 拍对齐；
5. W1 3×3 最大值膨胀、屏幕裁剪、零能量、全饱和和帧切换场景通过；
6. P bank 快照不存在撕裂：只在完整预取后切换活动 bank；
7. 独立综合、Verilator lint、TB 和 TD 资源/时序报告齐全；
8. 任何失败均能按上述探针或错误码分支定位，不以旧日志代替独立复跑。

## 产物清单

| 路径 | 产物 |
|---|---|
| `doc/brief/TASK_BRIEF.md` | 本任务范围、约束和审查 |
| `doc/brief/INTERFACE_SPEC.md` | W1/W2 冻结端口、状态表/P 表、时序 |
| `doc/brief/VERIFICATION_CONTRACT.md` | 场景、黄金、协议和资源门禁 |
| `doc/brief/START_PROMPT.md` | 执行方启动提示 |
| `reference/UPSTREAM_FACTS.md` | 上游文件、字序和只读边界 |
| `reference/gen_state_vectors.cjs` | W2 180+120 帧状态黄金生成器 |
| `reference/gen_overlay_vectors.cjs` | W1 覆盖层独立逐像素黄金生成器 |
| `rtl/pcb_frame_updater.v` | W2 实现方交付 |
| `rtl/pcb_particle_overlay.v` | W1 实现方交付 |
| `tb/` | 两模块独立 TB 与合体 smoke TB |
| `sim/` | Verilator/仿真脚本、日志和结构化结果 |
| `doc/output/` | 行为规格、编译/仿真/TD 报告 |

## 六维设计审查

| 维度 | 结论 |
|---|---|
| 功能边界 | W2 只更新状态，W1 只读取快照并产生覆盖层；不侵入 S2 和主线 |
| 时钟域 | W2 只在 50MHz 控制域运行；W1 只在 25.2MHz 像素域运行；`state_epoch` 采用 toggle 同步，P/T2 读口为同步读 |
| 资源占用 | P 表为 2048×16 的 1×32K；W1 行区段池为 6144×24bit，目标 ≤6×32K；W2 状态数组优先 9K/LUTRAM，不引入外部存储 |
| 时序收敛 | W1 有效像素路径只做行缓存查询、最大值、调色 ROM 和输出寄存；复杂几何在非有效期完成 |
| 稳定性 | 快照双 bank、状态提交 toggle、固定延迟、溢出 sticky、全整数边界裁剪 |
| 可扩展性 | 走线/节点数量仍受 S2 标签位宽限制；粒子 P bank 独立，不影响 T1/T2；未来可将覆盖层扩展为更多 primitive 类型 |

