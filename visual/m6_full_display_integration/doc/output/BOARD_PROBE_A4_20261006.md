# A4 只读计数位历史与复位事件位（2026-10-06）

**已出位，真卡待测；未宣称修复。** A3校准正确后仍无线稿：d1/d4滚动、d2固定57344、d3=32768、d5=270、d6复读20480，确定观测为BOOT/SD初始化IDLE/reader IDLE/eng_init1。旧d6=270已由用户复读更正，原始记录保留。

主板位：[M6_FDI_A4_20261006_343714AA.bit](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration/deliverables/M6_FDI_A4_20261006_343714AA.bit)；636626字节；SHA256 `343714aaa27eec0f317dc4b546e591496cc16cfc0ba6c0f56f3faff3d40d8fe8`。副板7175ECC3和受控TF卡不变。完整隔离实验源、TD与回归在 `experiments/board_0x46_A4_work`，最终阶段 `bit_a4_final`。

A4相对A3仅一个RTL文件内的临时观测逻辑与只读连接改变，功能watchdog/state、PLL、MISO两级、SPI/SDRAM/CRC、卡布局、W2/S2与效果保持原样。新增观察没有功能控制反馈；94源、五驱动正文、A3封存330/A2封存319/R2封存400、保护81项均核验一致。只读逆变换及逐文件差异在隔离包 `doc/output/SOURCE_GUARD.json` 和 `SOURCE_DIFF.patch`。

| 实测 | 结果 |
|---|---|
| 最终MSlice | 4677/4900，余223 |
| 物理LUT / REG | 16338 / 11381 |
| ERAM9K / ERAM32K / DSP / PLL | 43 / 5 / 18 / 3 |
| Setup / Hold | +1.123ns / +0.027ns，违例0 / 0 |
| 精确CDC | 108首级数据端+1024多周期数据端，1132逐条命中，误豁免/别名OPEN0 |
| ROM / 事件物理审计 | 512 INIT字一致；29历史位CTRL驱动、复位重现寄存器基准时钟驱动，均独立KEY1复位 |
| 回归 / lint | 11加载、2快照、只读事件测试通过；加载/W2严格0告警，应用0错误/346告警OPEN |

新增一条SYNCASYNCNET：已存在的异步ctrl_rst_n被只读基准域监视器采样；功能复位路径不变，不压告警。CTRL复位释放监视保留关联时钟定时，没有新增宽泛豁免；PLL锁定为硬宏异步状态，经两级采样，STA通过不保证事件捕获率。初次综合SDC不正确加载及物理过程别名告警保留，最终签核采用明确重载的物理约束。三项原卡/SDRAM模型哈希一致，模型结果不代替真卡或bit读回。

## 真卡操作

1. 烧本位，SW0=1：d0=**05464**、d7=**65280**确认版本与校准。d7仍是固定值。
2. KEY1按住约1秒放开，等待12秒；保持SW0=1逐页记录 **d1、d2、d3、d4、d5、d6**，每页至少等待0.3秒。d1/d2现在是锁存的位历史，不必追读瞬时计数。
3. 不再复位，再隔10秒重读 **d1、d2、d4、d6**；切SW0=0记录完整普通显示和屏幕。
4. 若线稿出现，仍须≥10分钟稳定、动态及KEY1复现。本轮仅观测也改变物理布局，单次成功不唯一证明任何修复假说。

| 页 | 含义 |
|---|---|
| d0 | 05464，A4识别 |
| d1 | watchdog低16位“曾为1”的按位OR历史 |
| d2 | [12:0]watchdog高13位历史；[13]ctrl_rst_n；[14]PLL locked；[15]key1 |
| d3 | [14:0]SDRAM等待cnt；[15]eng_init，保留A3 |
| d4 | 锁存事件标志，见下表 |
| d5 | A3复位/引擎标志；[0]init_ready、[1]eng_init、[2]reader R1 bit7、[3]ctrl_rst_n、[5:4]CTRL复位同步状态、[6]global reset、[7]PLL reset、[8]key1 |
| d6 | A3原状态字；[3:0]store、[7:4]init、[12:8]reader、[13]mem_busy、[14]eng_init、[15]init_ready |
| d7 | 固定65280高位校准 |

| d4位 / 十进制权重 | 曾观测到的事件 |
|---|---|
| 0 / 1 | watchdog bit16为1 |
| 1 / 2 | watchdog恰等499999 |
| 2 / 4 | store状态非BOOT |
| 3 / 8 | BOOT观测期间watchdog bit15由1到0（回绕或清零均可触发） |
| 4 / 16 | 首次稳定释放后，CTRL复位重现 |
| 5 / 32 | 首次稳定释放后，PLL解锁 |
| 6 / 64 | CTRL边沿出现 |
| 7 / 128 | store状态大于11 |

例如d4=72只表示CTRL边沿和BOOT时低位回落被锁存；结合d1=65535、d2低13位0，可支持低16位活动而高位未见1。复位事件没有置位也不能排除短于基准采样窗口的脉冲。CTRL实际频率尚未测定，仅看边沿活动不排除频率异常，不能因此唯一认定进位故障。d1/d2历史**不是数值最大值、不是同一时刻计数**，不能按A3公式还原瞬时watchdog。所有锁存只有KEY1清除。

页位SW[3:1]从d0至d7为000、001、010、011、100、101、110、111。基准复位监视仅在采样到CTRL释放且PLL锁定后武装，启动正常复位不记为异常。新增事件测试覆盖停CTRL后基准观察继续、内部复位不清历史、KEY1清两个域、实际数码管65535/65280转换。

本轮选择依据、限制及A3最终读数见 `doc/brief/BOARD_PROBE_A4_SCOPE_20261006.md` 和 `doc/output/A3_PROBE_BOARD_ANALYSIS_CONFIRMED_20261006.md`。没有硬件验收或上游登记写入。
