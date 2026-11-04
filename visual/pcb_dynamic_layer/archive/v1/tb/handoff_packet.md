# Handoff Packet — pcb_dynamic_layer

> 最后核对日期：2026-10-04  
> 维护者：视觉子系统负责人  
> 状态：W2 默认/协议仿真通过，LUT 门禁失败；W1 探针是待实现清单，不表示信号已经存在。

## 1. 实现方交付边界

- `rtl/pcb_frame_updater.v`：只负责 W2 每帧动力学和 T1/T2/P 写口；
- `rtl/pcb_particle_overlay.v`：只负责 W1 快照预取、行分桶、光栅化和覆盖层输出；
- 不修改 S2 `task_045_pcb_pixel_renderer`、`prototype/`、`spec/` 或主线 RTL。

## 2. ChipWatcher 探针清单

| 信号 | 位宽 | 触发条件 | 预期现象 |
|---|---:|---|---|
| `frame_tick` | 1 | 每次请求频谱帧 | 只有 ready 时接受，重复 tick 不覆盖 busy 帧 |
| `frame_accept` | 1 | W2 接受新帧 | 只在 `frame_ready=1` 的 tick 后出现 |
| `state[6:0]` | 7 | W2 内部状态机 | T1→T2→P→commit，顺序不回退；映射见 RTL localparam |
| `state_wr_addr/state_wr_lane` | 8/2 | W2 T1/T2 写口有效 | T1 地址/lanes、T2 0..139 单调完整 |
| `part_wr_addr` | 11 | W2 P 写口有效 | 0..1535 单调完整 |
| `state_commit_toggle` | 1 | 完整快照提交 | P 最后一拍后翻转一次 |
| `snapshot_ack_toggle` | 1 | W1 预取完成 | 只在所有 T2/P 快照缓存完成后翻转 |
| `k[6:0]` / W1 待实现 particle_index | 7 | P 更新/预取 | 0..127 循环，不能越界 |
| W1 待实现 `bucket_ref_count` | 13 | 行区段写入 | 合法占用 0..6144，最大写地址 6143；超限锁存 overflow |
| `bucket_overflow_sticky` | 1 | 行区段池溢出 | 正常场景为 0；故意超限场景为 1 |
| `overlay_hit` | 1 | 输出覆盖命中 | 仅在柱顶线、粒子轨迹或粒子头部命中时为 1 |
| `overlay_valid` | 1 | 输出有效 | 与输入 `in_valid` 固定延迟 647 拍，无帧尾杂散 |
| `overlay_rgb565` | 16 | 输出命中 | 与独立 W1 黄金逐位一致 |
| `err_valid/err_code` | 1/4 | 异常 | tick overrun、地址越界和提交不同步可区分 |

## 3. 取证纪律

- 探针通过 TD `Read Design` 临时添加，源码不得保留 `MARK_DEBUG`；
- 首次采集优先使用 `state_commit_toggle` 和 `bucket_overflow_sticky` 触发；
- 若无覆盖输出，按“提交 toggle → P/T2 预取 → 行桶 → 输出延迟”顺序分层定位；
- ChipWatcher 证据只用于定位，不替代独立黄金和全帧对拍。
