# A2 上板读数解码与下一步（2026-10-06）

> 编制：浮浮酱（规格/验收方）｜ 对象位：`M6_FDI_A2_20261005_7B97635A.bit`
> 状态：**A2 真卡实测 FAIL（现象与 R2 相同：无线稿）**；本轮获得首份故障态读数
> 交付对象：执行方（国模）

---

## 1. 实测读数（主人上板，2026-10-06）

| 项 | 观察 |
|---|---|
| SW0=1、SW[3:1]=000 | d0 显示 **05462** ✅ A2 识别页正确，**拨码映射自检通过** |
| SW0=0 + KEY1 复位放开 | 屏幕**一直无线稿**；d0 保持 **05462** |
| P1..P6 | 全部 **0** |
| P7 | 报 **05401**（存疑，见 §5） |

## 2. 按执行方自带解码表的判读

页位定义（`experiments/board_0x46_A2_work/doc/output/BOARD_PROBE_A2.md`）：

- **P1[3:0] = store state**，取值表 `0=BOOT 1=INIT 2=SECTOR_START 3=LOAD 4=DRAIN 5..9=CHECK_* 10=READY 11=ERROR`
- P1 = 0 ⇒ **store = BOOT**
- P2 = 0 ⇒ `sector_number=0`、`write_pending/eng_ready/init_busy/cmd_busy/init_byte_busy` 全 0
- P3 = 0 ⇒ `bytes_seen = 0`
- P4 = 0 ⇒ `command state=0`、`init byte state=0`，且 **cmd_done / cmd_timeout / init_error / init_done / sector_busy / sector_valid / eng_resp 全 0**
- P5 = 0 ⇒ `write_index = 0`
- P6 = 0 ⇒ `memory state=0`、`init_code=0`，且 **sticky 六位（init_done / init_error / cmd_done / cmd_timeout / init_byte_done / eng_resp）全 0**

## 3. 结论（与位宽/编码无关的那部分，最硬）

**P4 与 P6 的握手标志位全 0 ⇒ 加载链自始至终没有完成过任何一次命令交互。**

这一条**不依赖于 P1 的 state 编码假设**：无论 FSM 卡在哪个编号，`cmd_done / cmd_timeout / init_done / eng_resp / sticky` 全零只可能意味着——**从来没跟 SD 卡说过话**。

由此**排除**：

| 被排除项 | 依据 |
|---|---|
| **D-21 §5.1 (A)「停在 INIT，等 cmd_done 静默挂起」** | 从未进入 INIT（P2 的 cmd_busy/init_byte_busy=0，P4 的 command state=0） |
| **D-21 §5.1 (B)「停在 SECTOR_START，eng_init 不来」** | sector_number=0 且 sector_busy=0，从未发起扇区请求 |
| **D-21 §5.2 头号嫌疑「MISO 4 级缓冲」** | BOOT 状态**完全不触碰 SPI**。本轮唯一功能改动（4 级→2 级）在故障路径之外 ⇒ **A2 不可能修好它，故障签名不变正是证据** |
| 「数据读错」类 | 全部数据错误路径（0x40/41/42/43/48/49）无一触发，与 P4/P6 全 0 一致 |

**⇒ 真正的挂起点比 D-21 的所有假设都更靠前：FSM 停在 `BOOT`（上电启动延时），从未发出 `init_start`。**

## 4. 与 RTL 的硬矛盾（请执行方优先解答）

`fdi_label_store.v`：

```verilog
localparam BOOT=0, ...;                                  // state 明文 4 位二进制，无 one-hot 属性
reg [3:0]  state;
reg [28:0] watchdog;
parameter integer STARTUP_CYCLES      = 500000;          // 50MHz → 10 ms
parameter integer BOOT_TIMEOUT_CYCLES = 500000000;       // 50MHz → 10 s
localparam [28:0] START_LIMIT = STARTUP_CYCLES[28:0]      - 29'd1;   // 499999
localparam [28:0] BOOT_LIMIT  = BOOT_TIMEOUT_CYCLES[28:0] - 29'd1;   // 499999999

BOOT: if (watchdog == START_LIMIT) begin init_start<=1; state<=INIT; end   // ← BOOT 唯一出口
...
if (state!=READY && state!=ERROR) begin
  watchdog <= watchdog + 1'b1;                            // 非 READY/ERROR 时无条件递增
  if (watchdog == BOOT_LIMIT) fail(8'h46);                // ← 实测 10 秒触发
end
```

**矛盾**：同一个 `watchdog` 在 BOOT 态**无条件单调递增**。既然它数到了 `BOOT_LIMIT`（499999999）从而触发 0x46，就**必然在途中精确取到过 `START_LIMIT`（499999）**——那一步就该跳 INIT。**两个条件不可能同时成立。**

⇒ 二者之一必然为假：

- **(a) 综合后的 `START_LIMIT` 常量不是 499999**（首要嫌疑：`STARTUP_CYCLES[28:0]` 是对 **`integer` 做位选**，Verilog-2001 中 integer 是原子类型、不支持位选，TD 的实际求值需核实）；
- **(b) 探针采到的 `state[3:0]` 不是源码里的 0..11 编码**（若 TD 对 12 态 FSM 做了 one-hot/重编码，P1 的解码表全错）。

**注**：无论 (a)/(b) 哪个成立，**§3 的结论都不受影响**（P4/P6 标志位与编码无关）。

## 5. 需要先澄清的读数疑点（主人侧）

**P7 报 `05401`，而 `05401` 恰好是普通版本页的值，可疑。** P7 的定义是 `[7:0] init R1；[15:8] reader R1`，与版本号无关。可能的解释：切到 P7 时 `sw[0]` 实际回到了 0（普通 bank），或页序数错（`sw[3:0]` 对应 1/3/5/7/9/11/13/15，即 P0..P7）。**请复测一次 P7 后再下定论**；另外请确认 SW0=0 时 d0 究竟显示什么（按设计应优先显示原错误码）。

## 6. 执行方处置要求

1. **先答 §4**：给出 `START_LIMIT`/`BOOT_LIMIT` 在门级网表中的**实际比较常量**，以及 `state` 寄存器的**实际编码**（两者都要证据，不要复述源码）。
2. **若 (a) 成立**：这是**功能性缺陷**，与 MISO 无关。修复方向 = 让启动延时比较在硅上真实可达成（例如去掉对 `integer` 的位选、改用显式 29 位常量或 `$clog2` 安全写法），并在**真卡**上复现验证。
3. **若 (b) 成立**：先修解码表，再重下结论；不得据错误编码继续推断状态。
4. **A2 的 MISO 实验判定**：本读数**不支持** MISO 假设，但**不构成推翻**（因为故障点在 BOOT，A2 根本没走到 SPI）。**是否回退 MISO 改动由主人裁定**；建议在 §4 澄清前**冻结**该改动，不再叠新变量。
5. **禁止**：在无 §4 证据前盲改加载 RTL、盲加/减 MISO 缓冲、或以模型结果替代真卡复现。
6. **保留**：A2 位与其证据、R2 封存件、受控卡与本次读数记录，一并归档。

## 7. 证据锚点

- 读数来源：主人 2026-10-06 上板观测（本文件 §1）
- 位：`deliverables/M6_FDI_A2_20261005_7B97635A.bit`（SHA256 `7b97635a…2284cd57c`，636626 B，浮浮酱已核）
- 源码：`experiments/board_0x46_A2_work/project/src/rtl/fdi_label_store.v`（例化 `v9_m6_hdmi.v:31` 未覆盖 `STARTUP_CYCLES`）
- 网表：`experiments/board_0x46_A2_work/td_run/bit_a2_final/route_netlist.v`
- 页位定义：`experiments/board_0x46_A2_work/doc/output/BOARD_PROBE_A2.md`
- 前情：`doc/output/BOARD_FAULT_0x46_20261005.md`（D-21）

---

*浮浮酱 2026-10-06 ｜ 关联：`docs/DECISION_LOG.md` D-21 / D-26*
