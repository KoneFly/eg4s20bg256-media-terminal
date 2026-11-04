# M6 动态层接口冻结审计

> 最后核对日期：2026-10-02  
> 维护者：视觉子系统负责人  
> 状态：任务包交接准备完成；尚未进入 RTL 实现/TD 综合/板级验收。

## 1. 本轮完成项

- 已创建任务包四件套：`doc/brief/TASK_BRIEF.md`、`INTERFACE_SPEC.md`、`VERIFICATION_CONTRACT.md`、`START_PROMPT.md`；
- 已创建 `reference/UPSTREAM_FACTS.md`、W2 状态黄金脚本和 W1 覆盖层黄金脚本；
- 已确认不修改 S2 `task_045_pcb_pixel_renderer`、不修改 `prototype/`、不碰主线 RTL；
- 已把 P 粒子表冻结为 `2048×16` 物理形状，避免用 `128×256` 宽 RAM 造成错误的 ERAM 资源估算；
- 已把 P 写序冻结为全局字地址 `0..1535`，每个粒子连续占用 12 个 16bit 字；
- 已明确 W1/W2 之间使用 `state_commit_toggle` / `snapshot_ack_toggle` 双向 2FF toggle；
- 已明确 W1 采用 4096 区段池、3×3 max、固定 D=647 拍输出对齐。

## 2. 已冻结的关键接口决策

### W2

- 输入：50MHz `clk`、单拍 `frame_tick`、`spec_frame[1023:0]`；
- T1/T2 写口：逐字匹配 S2 `wr_sel/wr_addr/wr_data/wr_lane` 语义；
- P 写口：`part_wr_en`、`part_wr_addr[10:0]`、`part_wr_data[15:0]`；
- 正常帧写序：T1 512 拍 → T2 140 拍 → P 1536 拍 → 翻转 `state_commit_toggle`；
- 在 `snapshot_ack_toggle` 返回前拒绝下一次 `frame_tick`，并锁存 overrun 错误。

### W1

- 输入：25.2MHz 像素流 `in_valid/in_sof/in_eol/in_x/in_y/in_ridx`；
- P 读口：同步读 `part_rd_addr[10:0]` / `part_rd_data[15:0]`，快照阶段缓存有效地址 0..1535；
- T2 只读取音柱字 64..127 和全局字 137，并在快照阶段镜像缓存；
- 输出：`overlay_valid`、`overlay_hit`、`overlay_rgb565`、`overlay_alpha`；
- 输出与 S2 使用相同固定 D=647 拍对齐，帧尾不产生额外有效输出。

## 3. 独立黄金脚本验证

### 脚本语法

以下两个脚本均通过 `node --check`：

```text
node --check rtl_handoff/pcb_dynamic_layer/reference/gen_state_vectors.cjs
node --check rtl_handoff/pcb_dynamic_layer/reference/gen_overlay_vectors.cjs
```

### W2 smoke

使用 `gen_state_vectors.cjs --scenario mixed --boot 1 --play 1` 生成两帧：

| 文件 | 行数 | 行宽 |
|---|---:|---:|
| `state_trace.hex` | 128 | 32 hex 字符 |
| `state_misc.hex` | 140 | 8 hex 字符 |
| `state_particles.hex` | 1536 | 4 hex 字符 |

P 快照每 12 行对应一个粒子，符合 128×12 的逻辑布局。

### W1 smoke

使用两帧状态快照运行 `gen_overlay_vectors.cjs`：

```text
span_pool_depth = 4096
span_count_max  = 2467
hit_pixels      = 7332 / 7766
fixed_delay     = 647
```

本 smoke 只验证黄金脚本、状态打包、P 字序和覆盖层容量计算；不构成 RTL PASS、TD PASS 或板级 PASS。

## 4. 尚未完成项

- RTL、TB、`sim/run.sh`、TD Tcl 和综合报告尚未创建；
- W2 逐帧 180+播放段黄金尚未批量导出；
- W1 全帧逐像素 TB 尚未实现；
- S2+W1 合体台和 S6 合成未实现；
- 没有任何板级证据，不能宣称硬件 PASS。

## 5. 结论

当前包已经从“接口缺口审计”推进到“可交给验收方检查的正式交接包草案”。
下一步应由验收方确认接口草案，确认后再立项给 RTL 实现方；实现方不得在未确认前自行改端口、P 字序、写序或固定延迟。
