# Verification Contract — pcb_dynamic_layer

> 最后核对日期：2026-10-04  
> 维护者：视觉子系统负责人  
> 黄金原则：黄金来自独立 JavaScript 参考模型和固定状态向量，不从 RTL 公式反推。

## 1. 总体判据

W1、W2 必须分别独立验证，再进行一次离线合体验证：

- **W2**：每个测试帧导出 T1/T2/P 三张状态快照，逐字段、逐字、逐位与黄金比较；
- **W1**：固定状态快照 + 完整 640×480 输入像素坐标流，逐像素比较 `overlay_valid/overlay_hit/overlay_rgb565/overlay_alpha`；
- **合体**：S2 `pcb_pixel_renderer` 输出与 W1 覆盖层经独立合成参考式组合，比较完整 640×480 帧。

任何 1bit 差异均为 FAIL。TB 必须 fail-fast，首个失配打印场景、帧号、地址/坐标、期望值和实际值。

## 2. W2 场景矩阵

### 2.1 固定场景

| 编号 | 场景 | 帧数 | 频谱刺激 | 检查 |
|---|---|---:|---|---|
| W2-01 | reset_zero | 1 | 复位保持；无 tick | 所有内部状态和首个快照为 0，输出写使能为 0 |
| W2-02 | boot_silence | 180 | 128 路全 0 | 每帧 T1/T2/P 与黄金相等；走线只生长，能量相关字段保持衰减语义 |
| W2-03 | boot_low | 180 | 启动阶段低频固定图样 | B[0]/B[1]、片内低频表、低频柱响应正确 |
| W2-04 | playback_low | 120 | 低频脉冲 + 平滑衰减 | 走线 flow、节点、低频柱和 onset/cool 正确 |
| W2-05 | playback_mid | 120 | 中频扫频和离散起音 | 3 槽脉冲、节点命中、beatK 正确 |
| W2-06 | playback_high | 120 | 高频扫频 | 高频柱、峰值帽和彗星角度/方向正确 |
| W2-07 | impulse_broadcast | 64 | 每 16 帧一次低频突发 | `loOn` 广播、全板脉冲和环上彗星正确 |
| W2-08 | saturate | 16 | 每路 255 | 饱和、裁剪、冷却、粒子槽顶替规则正确 |
| W2-09 | silence_decay | 120 | 先全 255 后全 0 | 包络、nodeK、inK、peakHold、彗星衰减无负值/下溢 |
| W2-10 | cfg_boundary | 16 | 运行时写参数最小/最大/越界值 | 参数只从下一 `frame_tick` 生效；越界饱和；不影响当前帧 |
| W2-11 | tick_overrun | 4 | busy 期间插入额外 tick | `err_code=1` sticky；当前帧不可被半途覆盖；不产生半份快照 |
| W2-12 | reset_reentry | 180 | 在更新和序列化中途复位 | 输出写口立即停止；复位后首帧从全零重新开始 |

### 2.2 W2 写口检查

每个正常帧必须产生：

- T1：512 个 `state_wr_en` 有效拍，地址/`wr_lane` 序列为 `(0,0)…(127,3)`；
- T2：140 个有效拍，地址严格为 0..139；
- P：1536 个有效拍，地址严格为 0..1535，每个粒子连续占用 12 个地址；
- `state_commit_toggle` 只在全部写入完成后翻转一次；
- `frame_done` 只持续一个控制时钟周期；
- `state_wr_en=0` 和 `part_wr_en=0` 时不得改变对外写数据语义；
- 下一次 tick 在 `snapshot_ack_toggle` 返回前必须被拒绝并置 overrun。

## 3. W1 场景矩阵

| 编号 | 场景 | 状态 | 检查 |
|---|---|---|---|
| W1-01 | all_empty | barH/barPeak=0，P 全 inactive | 全帧无覆盖命中，零杂散 valid |
| W1-02 | bar_top_line | 128 柱高度为阶梯/三角图样 | 柱顶连线端点、零高度邻接条件、扫描序和亮度 170 |
| W1-03 | particle_degenerate | 128 粒子 active，8 点全部相同 | 头点、十字点、3×3 膨胀和最大值合成 |
| W1-04 | particle_mixed | 粒子历史点来自 120 帧模型 | 7 条历史线段、生命衰减、能量亮度和裁剪 |
| W1-05 | saturate | 柱/粒子全亮，部分点在屏外 | 坐标裁剪；不产生负索引、X/Z 或越界写 |
| W1-06 | snapshot_swap | 连续两帧使用完全不同的状态图 | 预取未完成时继续使用旧 bank；完成后整帧切换，不撕裂 |
| W1-07 | bucket_limit | 构造超过 6144 个真实紧凑行记录的状态 | `bucket_overflow_sticky` 触发；TB 将其判为预期 FAIL，不允许静默丢线 |
| W1-08 | idle_gap | 在行间和帧间插入 `in_valid=0` | 坐标/状态冻结；无效期间不输出覆盖 valid |
| W1-09 | fixed_delay | 完整 640×480 连续有效帧 | 输出固定 D=647 拍，`in_sof/in_eol` 同延迟 |
| W1-10 | palette_boundary | `in_ridx=0/63`，亮度 0/190/255 | RGB565 量化、高光混白和 alpha 逐位正确 |

## 4. W1 黄金模型要求

`reference/gen_overlay_vectors.cjs` 必须：

1. 不例化或调用 DUT；
2. 独立实现 Bresenham、3×3 max、行区段合并、径向 palette 和 RGB565 量化；
3. 从明确的状态快照输入读取 bar/P 字段，不从 RTL 波形推导期望；
4. 对每帧输出：
   - `overlay_valid.bin`；
   - `overlay_hit.bin`（命中掩码，与 valid 分离）；
   - `overlay_rgb565.bin`；
   - `overlay_alpha.bin`；
   - `meta.json`（帧数、命中像素、区段数量最大值、溢出标志）；
5. 真实紧凑行记录打包/解包还原像素零失配；正常场景在生成结束时断言 `span_count_max < 6144`，否则生成器退出码非零。

W2 的 `reference/gen_state_vectors.cjs` 可以调用只读的 `prototype/pcb_model.js`，但必须明确记录模型 SHA256、频谱刺激和 pack 布局；不得读取 RTL 输出作为输入。

## 5. 合体验证

合体台输入：

- task_045 的 16bit RGB565 输出；
- W1 `overlay_rgb565/overlay_valid/overlay_hit/overlay_alpha`；
- `ov_on` 和底图 RGB565。

合体黄金使用与 `prototype/pcb_model.js::pcbComposite()` 同语义的独立函数：

```text
overlay_valid=0 或 overlay_hit=0 -> 透传 S2/底图路径；
overlay_valid=1 且 overlay_hit=1 -> 根据底图 Y=(R+2G+B)>>2 选择原色或 3/8 深色线；
out = bg + floor((target-bg)*m/256)，m∈{64,128,192,224}。
```

带符号差值必须使用 floor 语义，禁止用对负数不等价的移位分解代替整体乘法。

合体门禁：

- 完整 640×480 帧逐位相等；
- 连续完整输入帧上，S2 的 647 拍输出与 W1 的 647 拍覆盖输出逐像素对齐；W1 自然时钟断流检查独立执行，S2 任意断流重对齐由 S6 适配；
- W1 覆盖层不能改变静态 S2 的非命中像素；
- 帧尾无额外覆盖 valid。

## 6. TB 架构要求

- W1 与 W2 使用独立 TB，不共享被测模块内部状态；
- W2 的 P/T1/T2 存储模型放在 TB/集成侧，通过真实写口装载/读回，不允许后门强写 DUT 数组；
- W1 的 T2/P 读口使用同步一拍模型，显式验证请求地址与返回数据的相位；
- 使用 50MHz `ctrl_clk` 与 25.2MHz `pixel_clk` 两个时钟，任意相位关系均应稳定；
- 每个场景支持 `SCEN_ONLY=<name>`，默认不生成 VCD；
- fail-fast，单场景看门狗 60s；
- 输出 `sim_result.json`，至少包含 PASS/FAIL/TIMEOUT 计数、首个失配、最大区段数和固定延迟。

## 7. 验收门槛

1. Verilator lint 0 error、0 warning；
2. W2-02~W2-12 正常场景逐帧状态 0 失配；
3. W1-01~W1-06、W1-08~W1-10 逐像素 0 失配；W1-07 必须按预期触发溢出并 FAIL；
4. W1 固定延迟恒为 647 拍；
5. W2 写序列和 toggle 协议全部通过；
6. 至少一处故意变异被 TB 杀死：例如 `peak==0` 改为 `pos==0`、P 点 y 位宽减少 1bit、或 `>>8` 改为 `>>7`；
7. TD 独立综合报告 LUT/REG/DSP/ERAM、Setup/Hold WNS、违例端点和新增告警签名；
8. 未获得上板证据前不得写“板级 PASS”。

## 8. 资源和时间门禁

- W2 更新和序列化必须在下一帧 tick 前完成；
- W1 行分桶必须在有效像素期之外完成，不能在 25.2MHz 有效像素路径扫描全部粒子段；
- P bank 物理形状固定为 2048×16、1 块 ERAM32K，逻辑有效地址为 0..1535；
- 行区段池逻辑形状 6144×24bit，实际 ERAM 块数必须以 TD `#bram32k` 直读为准；
- 如果 TD 资源超出 `TASK_BRIEF.md` 目标，必须先提交降档/重构报告，不得静默改变粒子数量、历史点数或画面分辨率。
