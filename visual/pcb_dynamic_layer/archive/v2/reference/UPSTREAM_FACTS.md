# UPSTREAM_FACTS — pcb_dynamic_layer

> 最后核对日期：2026-10-02  
> 维护者：视觉子系统负责人  
> 本文只记录上游事实、接口来源和只读边界，不替代 `INTERFACE_SPEC.md`。

## 1. 参考文件与 SHA256

| 文件 | 职责 | SHA256（2026-10-02） |
|---|---|---|
| `spec/M6_PCB_SKETCH.md` | M6 效果和动力学规格 | `5DA64B6763CFD4E5C1858B09A2F5AE1D0ADDF0D98C996193FAD0494BAE6A2BD6` |
| `spec/M6_PCB_PORTING_PLAN.md` | 模块划分和阶段门禁 | `E7257181978EDA454B0E48665BE13878EE918680CE79D59F54DA17F7C267EE55` |
| `prototype/pcb_model.js` | 独立动力学/渲染参考 | `FBB2298FC26CEF6F3E951C03BDC4857EEE769209E57CE9E547A711D9996CF351` |
| `prototype/pcb_layout.js` | 静态几何与对象表来源 | `BA8DD3DA1F0E3DD869948EDFB4047FAB5AEE801BDE3242B7E47A7A43794C8B7E` |
| `prototype/pcb_labels.js` | 标签编码和烘焙来源 | `26D98F73B2E53AEE0AF5843E8491CAF4D8C283822501CEA71F7B018989EB83C0` |
| `golden/pcb/obj_tables.json` | S1 对象表、调色、行表 | 需在正式黄金生成时记录 |
| `iccoder_workspace/tasks/task_045_pcb_pixel_renderer/reference/gen_vectors.cjs` | T1/T2 `packState()` 权威 | 任务目录只读 |

> 上表第二行的 SHA 在录入时须以本地 `Get-FileHash` 输出为准；若校验不一致，停止生成黄金并更新本文。

## 2. 只读依赖

- S2 `pcb_pixel_renderer` 的 `INTERFACE_SPEC.md`、`behavior_spec.md`、`reference/gen_vectors.cjs` 只读；
- S2 的 T1/T2 端口、字段位宽、字节序和 647 拍延迟不得改动；
- `prototype/pcb_model.js` 的 `pcbStep()` 是 W2 状态黄金来源，`pcbRender()` 中覆盖层循环是 W1 视觉意图来源；
- `golden/pcb/obj_tables.json` 的 `traces=70`、`nodes=128`、`comps=18`、`bars=128`，与规格一致。

## 3. T1/T2 权威打包

唯一权威为 S2 `reference/gen_vectors.cjs` 的 `packState()`：

- T1 行内 4 个 32bit 段顺序为 `[31:0][63:32][95:64][127:96]`；
- T2 字节低位优先；节点/音柱每字包含偶数索引在低 16bit、奇数索引在高 16bit；
- `m[137]=coreQ | ovK<<8 | chipInk<<16 | beatK<<24`；
- `m[138]` 包含 B[0..3]，`m[139]` 包含 B[4..7]；
- `m[133+j]=(amp&255)|((dir&3)<<8)|((pos&0x3ff)<<10)`。

## 4. W1 P bank 的新增事实

P bank 是本任务新增的共享状态表，不属于 S2 T1/T2，不能改写 S2 的保留地址：

- 深度 128，对应 `PART_N=128`；
- 物理形状为 2048×16，地址 0..1535 有效，对应 1×32768bit ERAM32K；
- history[0] 是当前点，history[7] 是最旧点；
- 每点 21bit：x 为有符号 11bit，y 为有符号 10bit；
- energy/life/active 分别位于 [175:168]/[183:176]/[184]；
- P 的其他位必须写 0，避免 X/Z 传播和黄金不确定。

## 5. 黄金独立性

- W2 黄金从 `pcb_model.js` 的独立状态演进产生，再按固定 `packState()` 映射到写口快照；
- W1 黄金从固定 bar/P 快照和独立 Bresenham/3×3/区段合并程序产生；
- TB 不得例化黄金模型、读取 DUT 内部状态或使用同一个 RTL 辅助函数计算期望；
- 任何参考模型修改必须同步记录新的 SHA256 和影响场景。

## 6. 关键容量审计（默认冻结参数）

对参考模型进行 1200 帧、低频脉冲/扫频/全饱和/伪随机压力刺激，得到以下非验收替代数据：

| 项 | 观测最大值 |
|---|---:|
| 柱顶+粒子基础动态线段 | 1023（127+128×7） |
| 3×3 后最大单行非零像素 | 86 |
| 3×3 后全帧区段数 | 2359 |
| 建议行区段池 | 4096 |
| 建议单行区段引用容量 | 64 |

上述数字是容量设计证据，不是 RTL/TB 验收结果；正式黄金脚本仍须在 180 帧启动和规定播放段上重新生成并记录 `span_count_max`。

