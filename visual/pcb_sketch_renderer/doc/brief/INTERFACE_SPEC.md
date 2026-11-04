# Interface Spec — pcb_pixel_renderer（冻结契约）

> 签发：浮浮酱 ｜ 日期：2026-09-27 ｜ 上游效果规格：`spec/M6_PCB_SKETCH.md`
> **端口名称、方向、位宽、有效电平、状态表字段位置，均为冻结契约，不得修改或新增。**

---

## Module Declaration

```verilog
module pcb_pixel_renderer (
    // ---- 读侧：像素域 25.2MHz ----
    input  wire        clk,             // 像素时钟 25.2MHz
    input  wire        rst_n,           // 低有效，本域同步释放

    // 来自 async_pixel_fifo 的 {标签, 图像} 同拍像素（valid 与显示 DE 对齐）
    input  wire        in_valid,        // 1 = 本拍 in_label/in_image 有效
    input  wire [15:0] in_label,        // 16bit 标签（编码见 §标签编码）
    input  wire [15:0] in_image,        // 16bit 图像像素 RGB565（叠加模式的底图）

    // 叠加开关（像素域电平；由集成方在 VBLANK 同步后给出，本模块视作静态）
    input  wire        ov_on,           // 1 = 叠加模式（可视化层压在图像上）

    // ---- 状态表读口（真双口 BRAM 读侧；写侧见下方 wr_*） ----
    output wire [7:0]  st_trace_addr,   // 走线号 0..127
    input  wire [127:0] st_trace_rdata, // 走线状态记录（布局见 §状态表内存图 T1）
    output wire [7:0]  st_misc_addr,    // 杂项表地址 0..255
    input  wire [31:0] st_misc_rdata,   // 杂项记录（布局见 §状态表内存图 T2）

    // ---- 状态表写口：ctrl 域 50MHz（集成时由 pcb_frame_updater 驱动；TB 亦由此装载快照） ----
    input  wire        wr_clk,          // ctrl 域时钟 50MHz
    input  wire        wr_en,           // 写使能（单拍）
    input  wire        wr_sel,          // 0 = st_trace，1 = st_misc
    input  wire [7:0]  wr_addr,         // 写地址（st_trace：走线号；st_misc：字地址）
    input  wire [31:0] wr_data,         // 写数据（st_trace 为 128bit 记录的第 {wr_lane} 个 32bit 段）
    input  wire [1:0]  wr_lane,         // st_trace 用：0..3 对应记录 [31:0]/[63:32]/[95:64]/[127:96]

    // ---- 输出（已寄存） ----
    output reg  [15:0] pixel_rgb565,    // RGB565 {R[4:0],G[5:0],B[4:0]}
    output reg         pixel_valid      // 与输入 in_valid 同节拍，固定延迟后有效
);
```

**延迟契约**：`pixel_valid` 相对 `in_valid` 为**固定常数延迟**（由实现方在 `behavior_spec.md` 中声明，
TB 按该常数断言；建议 ≤16 拍）。固定延迟是硬要求——集成方按它对齐。

---

## 标签编码（来源：`prototype/pcb_labels.js`，S0 冻结）

`class = label[15:13]`：

| class | 含义 | 位域 |
|---|---|---|
| 0 | 空（透明） | — |
| 1 | 静态墨线 | `[12:8]` 墨量档（0-31）×8 得 0-248｜`[7]` 芯片核心位｜`[6:4]` 频段刻度 g+1（0=非刻度） |
| 2 / 3 | 走线 0-63 / 64-127 | `[12:7]` 线号低 6 位｜`[6:0]` 路径下标 k（0-127） |
| 4 | 大圆环 | `[12:3]` 角度 a（0-1023，1/1024 圈，0 = 正午顺时针） |
| 5 | 音柱 | `[12:6]` 柱号 col（0-127）｜`[5:0]` 径向偏移 r（实际半径 = 193+r） |
| 6 | 节点 / 片内元素 | `[12:6]` 编号 id（0-127）｜`[5:4]` 部位｜`[3:0]` 墨量档 ×16 |
| 7 | 元件 | `[12:8]` 元件号（0-31）｜`[7:0]` 墨量 |

部位编码（class 6）：`0`=仅墨线｜`1`=仅发光｜`2`=墨线+发光｜`3`=光晕。

---

## 状态表内存图（冻结）

### T1 `st_trace` — 128 深 × 128 位（有效项 0..69，即走线数）

地址 = 走线号 `i`。写侧按 4 个 32bit 段写入（`wr_lane`）。

| 位域 | 字段 | 说明 |
|---|---|---|
| `[15:0]` | `grow_q4` | 生长量，Q4（0 .. total×16） |
| `[23:16]` | `flow_e` | 电流能量包络 0-255 |
| `[31:24]` | `flow_ph` | 电流相位 Q4（只用地 8 位） |
| `[47:32]` | `slot0.pos_q4` | 脉冲头位置 Q4；**0 = 空槽** |
| `[55:48]` | `slot0.peak` | 脉冲峰值 0-255 |
| `[63:56]` | `slot0.age` | 脉冲年龄（帧） |
| `[79:64]` / `[87:80]` / `[95:88]` | slot1 同构 | |
| `[111:96]` / `[119:112]` / `[127:120]` | slot2 同构 | |

### T2 `st_misc` — 256 深 × 32 位

| 字地址 | 字段 |
|---|---|
| `0x00..0x3F` (0..63) | **节点对** `n`：`{vis[2n+1], b[2n+1], vis[2n], b[2n]}`（各 8bit） |
| `0x40..0x7F` (64..127) | **音柱对** `c`：`{barH[2c+1], barPeak[2c+1], barH[2c], barPeak[2c]}` |
| `0x80..0x84` (128..132) | **元件 fade**：每字 4 个 8bit（fade[4m+3..4m]），共 18 个 ⇒ 用 5 字 |
| `0x85..0x88` (133..136) | **彗星槽** `j`：`{amp[7:0], dir[1:0], pos[9:0], 12'b0}` |
| `0x89` (137) | **全局**：`{core_q8[7:0], ov_k[7:0], chip_ink[7:0], beat_k[7:0]}` |
| `0x8A..0x8B` (138..139) | **频段**：`{B[3],B[2],B[1],B[0]}` / `{B[7],B[6],B[5],B[4]}` |

> 其余地址读回 0，不得产生 X。

---

## 逐像素着色（来源：`prototype/pcb_model.js` `pcbRender()`，S0 冻结）

渲染器对每个输入像素算出一对 `(dark, light)`（各 8bit）。**除特别注明外全部为无符号整数运算。**

```text
// 全局量（每帧由 S3 写入，本模块只读）
core_q8, ov_k, chip_ink, beat_k, B[0..7]

cls = label[15:13]
```

### class 1 — 静态墨线
```text
lv      = label[12:8] << 3
core    = label[7]
tick    = label[6:4]
dark    = ((core ? (lv*core_q8)>>8 : lv) * chip_ink) >> 8
light   = tick ? (B[tick-1] >> 1) : 0
```

### class 2 / 3 — 走线
```text
i  = (cls==2) ? label[12:7] : 64 + label[12:7]
k  = label[6:0]
len= grow_q4 >> 4
if (k > len):
      dark = (k == len+1 && (grow_q4[3:0] != 0)) ? (208 * grow_q4[3:0]) >> 4 : 0
      light= 0;  return
light = (k == len && len < total) ? 200 : 0          // total 由 S3 写入？否 —— 见下
if (flow_e > 20 && len >= total && (((k<<4) - flow_ph) & 255) < 64):
      light = max(light, min(255, 180 + ((flow_e*75)>>8) + (beat_k>>2)))
for j in 0..2:
      pos = slot_j.pos_q4 ; if (pos == 0) continue
      d = (pos>>4) - k
      if (d < 0 || d >= 16) continue
      amp = (slot_j.age < 3) ? (slot_j.peak * (slot_j.age+1)) / 3 : slot_j.peak   // 整数除法，见注
      v = (d == 0) ? min(255, amp + 40) : (amp * (16-d)) >> 4
      light = max(light, v)
dark = 208
```

> **注 1（`total`）**：走线满长值不在状态表里——`len >= total` 的判据改为
> `slot_j.pos_q4` 与 `flow_ph` 的可用性：**S3 保证走线未长满时把 `flow_e` 写 0 且三槽 `pos_q4` 写 0**，
> 因此渲染器可省去 `total` 比较（等价化简，见 §已知的接口限制 1）。
> **注 2（`amp` 的 1/3）**：`age` 只可能取 0/1/2/≥3，故 `(peak*(age+1))/3` 用查表或
> `peak*{1,2,3}` 后右移——**必须与黄金逐位相等**，建议直接实现整数除法 `peak*(age+1)` 再 `div3`（可用乘法倒数或小 ROM）。

### class 4 — 大圆环（彗星）
```text
a = label[12:3]
light = 0
for j in 0..3:
      if (rc_amp_j == 0) continue
      back = ((rc_pos_j - a) * (dir_j ? +1 : -1)) & 1023      // dir=1 顺时针
      if (back < 90): light = max(light, (rc_amp_j * (90-back)) / 90)
dark = 232
```
> `/90` 与 `/3` 同属"必须逐位相等"的除法，建议统一用一个除法小 ROM 或倒数乘法实现。

### class 5 — 音柱
```text
col = label[12:6] ; r = label[5:0]
h   = (barH[col] * 34) >> 8
if (r == 0): dark = 150 ; light = 0 ; return
dark = 0
if (r <= h): light = (r == h) ? 240 : (90 + ((barH[col]*150)>>8))
pk = (barPeak[col] * 34) >> 8
if (pk > h+1 && r == pk): light = 250
```

### class 6 — 节点 / 片内元素
```text
id = label[12:6] ; part = label[5:4] ; il = label[3:0] << 4
if (vis[id] == 0): dark = 0 ; light = 0 ; return
if (part == 0 || part == 2): dark = (il * vis[id]) >> 8
if (part == 1 || part == 2): light = min(255, 40 + b[id])
if (part == 3): light = (b[id] > 120) ? (b[id] >> 2) : 0
```

### class 7 — 元件
```text
id = label[12:8] ; f = fade[id]
dark = (f == 0) ? 0 : (f * label[7:0]) >> 8 ; light = 0
```

---

## 输出级（顺序不可调换）

### ① 底部常驻 128 路柱形图（独立平面 `strip`，**不受 ov_k 影响**）

```text
仅当 y >= 451 时有值；每通道占 5 像素（x0 = col*5 .. col*5+3）
h  = (barH[col] * 28) >> 8 ; pk = (barPeak[col] * 28) >> 8
strip[x0..x0+3][479]      = 70
strip[x0..x0+3][479-kk]   = (kk == h) ? 235 : (110 + ((barH[col]*110)>>8))   for kk in 1..h
strip[x0..x0+3][479-pk]   = 250     if pk > h+1
```

### ② 3px 线宽：光/墨两层各自做 3×3 最大值膨胀
```text
可分离实现：先逐行做 3 邻域 max（需 1 行中间缓存），再逐列做 3 邻域 max（需 2 行缓存）
window = [k-1, k, k+1]，边界裁剪在 640×480 内
```

### ③ 径向 / 通道调色板索引（**无开方、无除法**）

```text
if (y >= 451):
      ch      = x / 5                                  // 用每 5 拍递增的计数器，不用除法器
      idx_ch  = round(ch * 59 / 127)                   // 128 项小 ROM（ch → idx）
else: idx_ch 用不到

// 半径索引：逐行增量法
//   行首：s = CXC + dy*dy（CXC = 320*320 = 102400）; r = 255
//   每拍：s += 2*(x-320)+1
//         while (s >= (r+1)*(r+1)) r++
//         while (r > 0 && s < r*r)  r--
//   idx_r = min(63, r >> 2)
```

### ④ 合成 → RGB565

```text
lg = (light * ov_k) >> 8
sv = strip                                     // 0 或 8bit
ll = max(lg, sv)
a  = max(light, (dark*190) >> 8)               // 190 = 128+64-2，用移位加实现，不用乘法器
v  = max(sv, (a * ov_k) >> 8)
if (v == 0): out = 16'h0000 ; done
v  = v & 8'hF8                                 // 32 档亮度量化
w  = (ll > 190) ? min(255, (ll-190)*4) : 0     // (ll-190)*4 = 左移 2 位
idx= (sv != 0 && sv >= lg) ? idx_ch : idx_r
r  = (PAL_R[idx] * v) >> 8                     // PAL_* 为 64 项 ROM（2048 项展开表更省 DSP）
g  = (PAL_G[idx] * v) >> 8
b  = (PAL_B[idx] * v) >> 8
if (w != 0):
      r = r + ((255-r)*w >> 8) ; g = g + ((255-g)*w >> 8) ; b = b + ((255-b)*w >> 8)
out = {r[7:3], g[7:2], b[7:3]}
```

**非叠加模式（`ov_on=0`）到此结束，`pixel_rgb565 = out`。**

### ⑤ 叠加合成（`ov_on=1`，来源 `pcb_model.js` `pcbComposite()`）

```text
bg_r = {in_image[15:11], 3'b0} ; bg_g = {in_image[10:5], 2'b0} ; bg_b = {in_image[4:0], 3'b0}
if (y >= 451): bg_r >>= 1 ; bg_g >>= 1 ; bg_b >>= 1        // 柱形图带：底图恒压暗 1/2
if (out != 0):
      v2 = max(out_r8, out_g8, out_b8)                     // out 展开为 8bit 后的最大值
      m  = LVTBL[v2 >> 6]                                  // LVTBL = {64,128,192,224}
      Y  = (bg_r + 2*bg_g + bg_b) >> 2
      tr = out_r8 ; tg = out_g8 ; tb = out_b8
      if (Y >= 128): tr = (tr>>2)+(tr>>3) ; tg = ... ; tb = ...      // ×3/8，同色相深色线
      bg_r = bg_r + ((tr - bg_r) * m >> 8) ; bg_g = ... ; bg_b = ...
out_final = {bg_r[7:3], bg_g[7:2], bg_b[7:3]}
```

> **底图口径**：黄金用**已量化到 RGB565 的图像**（先 `R5<<3` 展开再参与运算），与板上 SDRAM 里存的一致。

---

## 时序 / 协议细节

| 项 | 约定 |
|---|---|
| 吞吐 | `in_valid` 连续为 1 时，`pixel_valid` 亦连续为 1，**每拍一个像素，无气泡** |
| 延迟 | 固定常数（实现方声明），建议 ≤16 拍 |
| 复位 | `rst_n` 低有效；清零所有行缓存指针、写指针与输出寄存器；**状态表内容不属于复位域**（由写口决定） |
| 断流 | `in_valid=0` 时 `pixel_valid=0`，`pixel_rgb565` 保持上次值（不得为 X） |
| 跨域 | 状态表读侧在 `clk`、写侧在 `wr_clk`，用真双口 BRAM；**`wr_*` 与 `clk` 之间不得有组合路径** |
| 写冲突 | 同一地址在 VBLANK 内被写（集成方保证写只发生在消隐期、像素域不读该行标签）；本模块不做冲突检测 |

---

## 算术实现清单（精确性要求：全部与黄金逐位相等）

> 本模块**无浮点、无三角函数、无任意除法**。下表把规格里出现的每一次乘除列出并给出**精确**实现手段；
> 实现方可自行选择等价方案，但**必须证明逐位相等**（黄金 9 场景全帧比对即为证明）。

| 出现位置 | 运算 | 精确实现建议 | 代价 |
|---|---|---|---|
| class 1 | `(lv*core_q8)>>8`、`*chip_ink>>8` | 两个 8×8 乘法（可共用 1 个 DSP 分两级流水） | 1~2 DSP |
| class 2 | `(208*frac)>>4`（frac 为 4bit） | 纯移位加（`frac×208 = frac<<7 + frac<<6 + frac<<4`） | 0 |
| class 2 | `(flow_e*75)>>8` | 75 = 64+8+2+1 ⇒ 移位加 | 0 |
| class 2 | `peak*(age+1)/3` | `age+1 ∈ {1,2,3}` ⇒ 三选一；**除 3 用魔数乘法 `(n*0xAAAB)>>17`**，n = peak×{1,2,3} ≤ 765，**已全输入域穷举验证精确**（浮浮酱 2026-09-27 实测 0~767 全覆盖 0 失配） | 0~1 |
| class 4 | `amp*(90-back)/90` | 令 p = amp×n，n = 90-back ∈ [1,90] ⇒ p ≤ 22950；**魔数乘法 `(p*0x2D83)>>20`**，**已对 p ∈ [0,22950] 全输入域穷举验证精确 0 失配**（积 28bit，32 位有符号乘法器可容纳） | 0~1 |
| class 5 | `(barH*150)>>8`、`(barH*110)>>8`、`(barH*34)>>8` | 150=128+16+4+2、110=64+32+8+4+2、34=32+2 ⇒ 移位加 | 0 |
| class 5 | `*28>>8`（柱形图） | 28 = 32-4 ⇒ 移位加 | 0 |
| §③ 半径 | `(r+1)²`、`r²` 比较 | **增量维护**：r 变 ±1 时 r² 变 ±(2r+1) ⇒ 无乘法器 | 0 |
| §③ 通道 | `x/5` | 每 5 拍递增的计数器 | 0 |
| §③ 通道 | `round(ch*59/127)` | 128 项 ROM（ch → idx） | 0 |
| §④ | `(dark*190)>>8` | 190 = 128+64-2 ⇒ 移位加 | 0 |
| §④ | `(light*ov_k)>>8`、`(a*ov_k)>>8` | 2 个 8×8 乘法；**或用 (x,ov_k) 二维 ROM**（x 8bit × ov_k 8bit 过大 ⇒ 建议乘法器） | ≤2 DSP |
| §④ | `(PAL_*[idx]*v)>>8` | **展开为 (idx 6bit, v 5bit) → RGB565 的 2048×16 ROM**（4KB，1 块 BRAM） | 0 DSP，1 ERAM |
| §④ | 高光混白 `(255-r)*w>>8` ×3 通道 | 3 个 8×8 乘法；或 **(r 5bit, w 5bit) → 8bit 的 1024 项 ROM ×3 通道**（3KB） | ≤3 DSP 或 0 DSP |
| §⑤ 叠加 | `(tr-bg)*m>>8`，m ∈ {64,128,192,224} | **纯移位**：m/256 ∈ {1/4,1/2,3/4,7/8} ⇒ `x>>2`、`x>>1`、`(x>>1)+(x>>2)`、`x-(x>>3)` | 0 |
| §⑤ 叠加 | `Y=(bg_r+2bg_g+bg_b)>>2` | 移位加 | 0 |

**除法实现红线**：`/3` 与 `/90` 是规格中仅有的两个非常数友好除法，**必须做到逐位精确**：

| 除法 | 精确实现 | 输入域 | 验证状态 |
|---|---|---|---|
| `n/3` | `(n*0xAAAB) >> 17` | n ∈ [0, 765] | ✅ 全输入域穷举 0 失配 |
| `p/90` | `(p*0x2D83) >> 20` | p ∈ [0, 22950] | ✅ 全输入域穷举 0 失配 |

两者乘积均 < 2³¹（32 位有符号乘法器可容纳）。禁止用近似替代（黄金逐位比对会直接失败）。
实现方若改用其他方案，**必须自行穷举验证全输入域**并在 `run_report.md` 给出证据。

---

## 已知的接口限制

1. **`total` 不在状态表中**：走线满长判据由 S3 用「未长满时 `flow_e=0` 且三槽 `pos_q4=0`」的约定替代
   （等价化简，已由 `reference/vectors` 的黄金覆盖）。**禁止**在渲染器里另存 total 副本。
2. **不含粒子与柱顶连线**：本任务只做"标签着色 + 底纹 + 柱形图 + 膨胀 + 调色 + 合成"。
   音柱粒子轨迹与柱顶频谱轮廓线由后续任务（S2b，按行分桶的覆盖层光栅化）实现；
   本任务的黄金向量已把粒子/柱顶线置零。**禁止**在本模块内偷偷实现覆盖层。
3. **不做纸底模式**：仅黑底。`spec/M6_PCB_SKETCH.md` §6 的 `mode` 参数上板不使用。
4. **`ov_k` 必须精确**：`(x * ov_k) >> 8` 是黄金的一部分，不得用移位近似替代
   （否则逐位比对必失败）。
5. **半径索引在 x=0 处饱和**：`r` 由 255 起算并只按 §③ 的双向规则调整；
   实测 `x=0` 时真实半径恒 ≥ 320 ⇒ 索引恒 63，与黄金一致。
