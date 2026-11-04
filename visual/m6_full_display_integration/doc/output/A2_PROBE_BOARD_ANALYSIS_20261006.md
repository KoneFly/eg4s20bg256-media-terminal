# A2 第二次真卡读页分析（2026-10-06）

状态：用户实测无线稿，硬件验收 FAIL；此次已获得 SW0=1 下明确标为 d1～d7 的诊断页。挂起根因尚未定位，不将此记录升级为 PLL、复位或 MISO 的定论。

对象为本轮 A2 / 7B97635A。候选位当前 SHA256 为 `7b97635aadd6fa4ebab8f3fc598f195cde5bafcdf6b6968bf105ac62284cd57c`；本次用户操作与原话及解码结果保存于 `A2_PROBE_BOARD_READBACK_20261006.json`。主板位、受控卡和副板 7175ECC3 均无新增变更。

## 本次事实及解码

用户确认：页号 000，切换 SW0 两位置均无线稿；按住 KEY1 约 1 秒数码管熄灭；放开后不再复位，SW0=1 下读取以下值。普通 bank 的完整数码管显示、KEY1 放开至读取的间隔、间隔 10 秒重读结果尚未提供。不能将上一版 R2 的 60070 和 10 秒触发时刻替代这次 A2 观测。

| 页 | 十进制 | 十六进制 | 解码 |
|---|---:|---|---|
| d1 | 4096 | 1000 | store=BOOT(0)，init=IDLE(0)，reader=IDLE(16)，mem_busy=0，eng_init=0，init_ready=0 |
| d2 | 0 | 0000 | sector_number=0；write_pending、eng_ready、init_busy、cmd_busy、init_byte_busy 均为0 |
| d3 | 0 | 0000 | bytes_seen 低16位=0 |
| d4 | 112 | 0070 | command=IDLE(7)，init byte=IDLE(0)；bytes_seen 高4位及完成/错误/扇区响应标志均为0 |
| d5 | 0 | 0000 | write_index 低16位=0 |
| d6 | 0 | 0000 | memory=PWR_UP(0)，write_index 高2位=0，init_code=0，sticky 六位均为0 |
| d7 | 32512 | 7F00 | init R1=00；reader R1=7F |

累计 bytes_seen=0、write_index=0，扇区位置仍为 LBA64。解码调用：`python -X utf8 experiments/board_0x46_A2_work/scripts/decode_probe_pages.py 4096 0 0 112 0 0 32512`。

此次与第一次“全部零、P7版本号”不同：d1=4096 和 d4=112 恰好包含 reader 与 command 的初始空闲编码，具备实际快照特征。按 A2 的逻辑，快照复位值全零；这些非零值表明快照至少更新过，不能直接断言整个 CTRL 域从未获得时钟或一直完全保持复位。

## 优先定位方向

联合观测落在加载 BOOT 与 SDRAM PWR_UP，SD 初始化仍空闲、eng_init 未置位。CTRL 正常连续运行时，SDRAM 等待10000拍（50MHz下约0.2ms），加载 BOOT 等待500000拍（约10ms）。若这些数值在复位放开数秒后仍保持不变，应先核对 CTRL 时钟持续性、复位是否反复断言，以及 watchdog 与 SDRAM cnt 是否递增。

目前不具备这两个计数器或独立心跳的读数。加载 BOOT、memory PWR_UP 是观测状态；“为何不前进”仍不能在时钟停止、频率异常、重复复位、计数链问题或观测不一致之间唯一归因。

已有原生证据支持：START_LIMIT=499999，BOOT_LIMIT=499999999，gate 和最终 route 的29位条件一致；门级 BOOT 在 watchdog=499999 时下一状态为 INIT。详见 `A2_PROBE_STATIC_REVIEW_FINAL_20261006.json` 与 `A2_PROBE_GATE_BOOT_CHECK_20261006.json`。因此不依据 integer 位选猜测改启动常量。

此次进一步只读核对最终 `route_netlist.v`：C1/C3 都是 ENABLE、DIV=20，C1 CPHASE=19，C3 CPHASE=9；C1接 ctrl_raw→u_ctrl_buf→CTRL，C3接 mem_raw→u_mem_buf→SDRAM mem_clk。参数与连线正确不代替板上频率/持续性观测；不因主时钟数码管能扫描就断言派生 CTRL 正常。

## d7 的交叉核验点

reader 的 RTL 空闲复位 R1=FF；未发起请求而保持初始空闲时应仍为 FF。当前读出7F，与该条件不一致。

门级快照 bit111 的 D 直接连接 reader last_r1[7]；最终 route 的该快照 FF也由CTRL驱动并从 MI采该位，reader last_r1[7] 的物理 FF为异步 SET。这些静态路径没有解释读数高位为0的原因。需要延时重读及必要的常量校准，不能把7F当作已发生真实SD响应，亦不能忽略此处而仅依据状态编号修时钟。

## 下一次回传与后续分支

1. KEY1 放开至少12秒，SW0=0、页000，回传数码管完整前缀及五位数字。屏幕无线稿已记录，无须仅重复屏幕现象。
2. 不再复位，SW0=1，读取 d1、d6、d7；隔10秒再次读这三项，标明第一次和第二次值及间隔。
3. 若普通bank报60070而快照仍BOOT/PWR_UP，继续核对计数与快照一致性；若未报超时且快照持续保持这些值，优先补独立CTRL心跳、原始复位/PLL锁定、watchdog与SDRAM cnt的只读观测。新增诊断应另建隔离版本，并保持功能路径冻结。
4. 尚不修改加载控制、SPI/SDRAM驱动功能正文、CRC、MISO深度、时钟源或计数阈值。每个后续实际改位仍执行独立TD容量/最终0/0、精确CDC与既有回归，并要求真卡线稿出现及至少10分钟稳定。

本轮只有观测归档和原生配置复查；未生成新位、未重新综合/布线、未改封存件。上一份复查的 bank 疑点已由本次 d 页读数取得进展，后续使用本次真实快照，保留此前记录以还原操作过程。
