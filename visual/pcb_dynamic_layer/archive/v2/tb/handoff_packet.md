# Handoff Packet — pcb_dynamic_layer V2

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 状态：独立测量资料；未执行 ChipWatcher 采集或板级集成。当前预算与已知限制见 V2_MEASUREMENT_REPORT.md。

## 1. 交付边界

- `rtl/pcb_frame_updater.v`：保留每帧状态动力学、集中 16bit RAM、T1/T2 发布。
- `rtl/pcb_particle_overlay.v`：仅柱顶连线、T2 快照预取、行区段构建和固定延迟输出。
- `rtl/pcb_ram_2k16.v`、`rtl/pcb_span_ram.v`：同步词口与正式行池存储。
- 已删除粒子 P 读写接口；上游/S2/主线保持只读。

## 2. 已实现信号与后续探针建议

| 模块 / 信号 | 位宽 | 触发或观察点 | 当前语义 |
|---|---:|---|---|
| W2 frame_tick / frame_ready / frame_accept | 各 1 | 频谱请求 | 仅 ready 请求被接受；现场输入随后变化不影响当前帧 |
| W2 state | 6 | 控制流程 | 保留动力学→T1→T2→DRAIN→COMMIT；状态值见 RTL localparam |
| W2 state_wr_en/sel/addr/lane/data | 1/1/8/2/32 | 发布 | T1 512 写、T2 140 写，不存在 P 阶段 |
| W2 ram_we/ram_addr/ram_wdata | 1/11/16 | 内部串行 bank | 集中地址规划见 INTERFACE_SPEC.md |
| W2 state_commit_toggle / frame_done | 各 1 | 完整快照提交 | 最后 T2 写排空后翻转/单拍 |
| W2 err_valid / err_code | 1/4 | 非 ready 的 tick | sticky code=1，不能声称全部异常类别已实现 |
| W1 commit_meta / commit_sync / epoch | 各 1 | 接收 commit | 2FF 后锁定本次快照 |
| W1 state / fetch_addr | 6/8 | T2 快照预取 | 64..127、137；缓存后返回 ack |
| W1 snapshot_ack_toggle | 1 | 预取结束 | 允许 W2 后续更新；此时行池可能仍在构建 |
| W1 bar_index | 7 | 几何构建 | 0..127 柱；仅相邻 127 条线 |
| W1 alloc_count / pool_count | 各 13 | 辅助区/正式池计数 | 两者不同；正式池写地址最大 6143 |
| W1 row_start / row_count | 13/10 | 紧凑行表发布 | row_base/row_count，无 next 指针正式记录 |
| W1 pool_we / pool_waddr / pool_wdata | 1/13/24 | 正式行池写口 | 只在 in_valid=0 物理写入，长段分割为至多 64px |
| W1 publish_pulse | 1 | 行池完整发布 | TB 仅用于阶段完成观测，不用来生成黄金 |
| W1 fifo_count | 5 | 活动像素预取 | 有序 FIFO 占用，不在有效区扫描几何 |
| W1 bucket_overflow_sticky | 1 | 容量超限 | 正常八场景为零；故意溢出未执行 |
| W1 overlay_valid/hit/rgb565/alpha | 1/1/16/8 | 输出 | 独立黄金逐像素检查，自然时钟 D=647 |
| W1 sof_delayed / eol_delayed | 各 1 | 内部标记 | 与对应输入固定延迟 647 拍；未增加正式输出端口 |

上述是实际 RTL 信号和后续观测建议，不表示已经采集过硬件波形。粒子索引、P 字序、轨迹/头部命中等旧探针退役；旧清单保存在 archive/v1/tb/handoff_packet.md。

## 3. 取证纪律与限制

通过 TD Read Design 临时添加探针，不在源码留 MARK_DEBUG。建议按“W2 提交→W1 预取 ack→构建/发布→FIFO→647 拍输出”定位；ChipWatcher 不替代独立黄金。

当前 W1 TB 等待完整发布后开始有效帧；单活动池的中途切帧原子性尚未验证，最坏已测构建超过消隐期限。W2 setup 与两模块 LUT 门禁失败，不将此交接资料当作定板或系统接收结论。保持模块职责与正式接口清晰，不增加未授权集成步骤。
