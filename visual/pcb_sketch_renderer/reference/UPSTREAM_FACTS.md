# UPSTREAM FACTS — pcb_pixel_renderer 的上游事实

> 维护者：浮浮酱 ｜ 最后核对：2026-09-27
> **本文件只记录"以源码为准"的事实与文件指纹**；算法定义以 `INTERFACE_SPEC.md` 为准，效果意图以 `spec/M6_PCB_SKETCH.md` 为准。

---

## 1. 上游文件与职责

| 文件 | 职责 | 本任务的关系 |
|---|---|---|
| `visual_workspace/prototype/pcb_layout.js` | 版图几何（走线/节点/元件/音柱/填充） | 间接：标签图与对象表的来源 |
| `visual_workspace/prototype/pcb_labels.js` | **标签编码的权威定义**（`pcbBuildLabels`） | 直接：DUT 输入的位域含义 |
| `visual_workspace/prototype/pcb_model.js` | **渲染与动力学的参考实现**（`pcbRender` / `pcbStep`） | 直接：黄金的算法来源 |
| `visual_workspace/prototype/pcb_spec_fixed.js` | 定点频谱前端（128 路） | 间接：状态快照由它驱动音频 |
| `visual_workspace/prototype/bake_label_map.cjs` | 标签图烘焙（S1） | 间接：`PCB.BMP` 与 ROM |
| `reference/gen_vectors.cjs` | **黄金向量生成器** | 直接：产出本次验收的全部期望值 |

**只读**：以上文件本任务均不得修改。

---

## 2. 标签编码（与 `INTERFACE_SPEC.md §标签编码` 一致，来源 `pcb_labels.js` 头注）

```text
class = label[15:13]
 0 空
 1 静态墨线   [12:8] 墨量>>3(0-31)  [7] 芯片核心位  [6:4] 频段刻度 g+1（0=非刻度）
 2 走线 0-63  [12:7] 线号低 6 位    [6:0] 路径下标 0-127
 3 走线 64-127（同上）
 4 大圆环     [12:3] 角度 0-1023（1/1024 圈，0 = 正午顺时针）
 5 音柱       [12:6] 柱号 0-127     [5:0] 径向偏移（实际半径 = 193+偏移）
 6 节点/片内  [12:6] 编号 0-127     [5:4] 部位  [3:0] 墨量>>4
 7 元件       [12:8] 元件号 0-31    [7:0] 墨量
部位：0=仅墨线 1=仅发光 2=墨线+发光 3=光晕
```

**实际用量**（`golden/pcb/BAKE_REPORT.md` 实测）：走线 70/128、路径下标最长 110/128、
节点+片内 128/128（满）、元件 18/32、音柱 128/128、环角度 971 px。

---

## 3. 状态表内存图

见 `INTERFACE_SPEC.md §状态表内存图`（**冻结契约**，与将来的 S3 `pcb_frame_updater` 双向绑定）。

**打包实现见** `reference/gen_vectors.cjs` 的 `packState()` —— 它是"模型状态 → 冻结布局"的唯一映射，
可作为 TB 装载快照时的对照。

---

## 4. 向量格式（`reference/vectors/`）

| 文件 | 格式 |
|---|---|
| `label.bin` | 640×480 × 16bit **小端**，行主序；全部用例共用 |
| `<case>/state_trace.hex` | 128 行，每行 **32 个 hex 字符**（4×32bit，字符序 = `[127:96][95:64][63:32][31:0]` 的十六进制串，即行内前 8 字符对应写口的 `wr_lane=3`）。行为走线号 0..127 |
| `<case>/state_misc.hex` | 256 行，每行 8 个 hex 字符（32bit）；行号为字地址 0..255 |
| `<case>/image.bin` | 640×480 × 16bit 小端（叠加模式底图；非叠加用例全 0） |
| `<case>/expect.bin` | 640×480 × 16bit 小端 —— **期望输出**（逐位） |
| `<case>/meta.json` | `ov_on` / `core_q8` / `gain_q8` / 像素数 / 非零像素数 |

> `state_trace.hex` 的行内字符序与 `wr_lane` 的对应关系：若 TB 用 `$readmemh` 直接读成 128bit 宽数组，
> 则 `[31:0]` 段 = 该行**最后 8 个字符**。实现方可自行选择装载方式，但**写入口的字段语义不得变**。

---

## 5. 黄金的独立性声明（LESSON-001）

- 期望值由 `reference/gen_vectors.cjs` 调用 `pcb_model.js` 的 `pcbRender()` 生成；
- `pcbRender()` 是**独立于 RTL 的 JS 实现**（浏览器原型与离线视频用它出画），不是 RTL 公式的复写；
- 生成脚本已固定：**任何模型改动都必须重出全部向量并在 `reports/PCB_REVIEW.md` 登记**；
- 实现方**不得**用 RTL 反推或修改黄金。

---

## 6. 本模块的已知边界（与黄金的对应关系）

| 边界 | 说明 |
|---|---|
| 不含音柱粒子与柱顶连线 | 黄金用 `opt.noOverlay=1` 生成；这两项属 S2b |
| 不含纸底模式 | 黄金只跑黑底（`pcbRender` 的 `mode=0`） |
| 叠加模式的底图口径 | 黄金的底图是**已量化到 RGB565 再展开**（与板上 SDRAM 存的一致），不是原始 8bit 素材 |
| `core_q8` | 非叠加场景 = 256（不衰减）；叠加场景 = 90（芯片核心减淡，对应 `prototype/pcb_stage.js` 的 `{core:90}`） |
