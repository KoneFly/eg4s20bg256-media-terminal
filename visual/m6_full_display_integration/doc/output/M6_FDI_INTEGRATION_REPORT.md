# M6-FDI 集成与门禁报告

2026-10-04。当前状态：**HOLD_PHYSICAL_CAPACITY。已按用户后续授权完成固定RTL物理资源探测；打包需要5099个MSlice，超过器件4900上限，停止。无bit，无板测验收。** 以下保留完整门级测量、物理探测与验证证据。

用户已确认固定 PCB 文件与 640×480 裁剪方案，方案评审检查点通过。本报告记录该方案的完整 RTL 集成、模型验证与首次整体 TD 门级测量。按 START_PROMPT.md §3.1“超预算即停、报告待裁定，不得静默裁规格”，取得超限数字后停止 RTL 修改、布局布线与出位，仅收齐已启动验证和复核既有网表的约束载入。

## 1. 独立 TD 实测与口径

**物理探测是本轮最终停止依据。** `td_run/place1/console.log:334` 报 PHY-9009：MSlice5099 > 4900，超199（104.06%），也高于90%参考门限4410。已执行既有固定网表的冗余清理、全局放置和打包；打包时无法合法化，尚未完成布局，未执行布线。无完整物理 `report_area` / STA，不能登记 Routed 或0/0通过。

探测复用 `synth1g/gate.db`，全部61份编译RTL、两个include与ADC逐SHA一致，只改原SDC循环的执行写法；物理输入清单 `place1/SOURCE_MANIFEST.json` SHA256 `2aaf9caf56d82ade5d31971ee209efd9027ba587394eb6021072cb1286bb57f0`。TD清理后日志曾记录12338逻辑LUT/12001seq/46BRAM/18DSP；这些内部阶段计数不能代替器件Utilization计数。最终打包仍需5099个MSlice，说明冗余清理并未使本树合法落入器件。

TD原生place错误后落入交互提示、后续Tcl未运行；仅关闭本任务PID17580（进程名和启动时间身份一致），留存原始日志。脚本随后补catch，防止未来错误留下等待提示；未因此重新物理实现或改变测量结果。

器件 EG4S20BG256，TD v6.2.168116；阶段 **Synthesized**，尚未执行物理清理、布局或布线。面积取 `td_run/synth1g/gate.area` 的 **Utilization Statistics**，不以 `#Total_luts=15068` 或 QoR 的 `#luts=15068` 替代资源门禁计数。

| 资源 | 实测 | 器件容量 | 占用 | 90% 整数门限 | 结果 |
|---|---:|---:|---:|---:|---|
| LUT | 21206 | 19600 | 108.19% | 17640 | FAIL，超过门限3566，超过容量1606 |
| REG | 16424 | 19600 | 83.80% | 17640 | PASS |
| ERAM9K | 42 | 64 | 65.62% | 57 | PASS |
| ERAM32K | 5 | 16 | 31.25% | 14 | PASS |
| DSP | 18 | 29 | 62.07% | 26 | PASS |
| PLL | 3 | 4 | 75.00% | 3 | PASS |

引脚：`#pad=54/188`，含基座 HDMI 4 个隐式负端；新 TF 四线无冲突。片内 SDRAM 使用 EG_PHY_SDRAM_2M_32，内部 S 引脚不挤占上述外部 GPIO。

**时序采用复核文件 `checked.qor` / `checked.timing`**：在同一份 `gate.db` 上重新载入原冻结 SDC，仅执行 `update_timing`，没有重综合、优化、布局或 RTL 改动。9 个时钟均出现，STA coverage 99.77%；Setup WNS **−5.044 ns，7 个违例端点**；Hold WNS **+0.471 ns，0 个违例端点**。未达到 0/0 门禁。

这 7 个 Setup 端点均为 scan 的 CDC 第一同步级：`label_meta`、`ready_meta`、`capture_ack_meta`、`commit_meta`、`write_bad_meta`、`blank_meta`、`capture_meta`。对应 SDC 使用 `foreach`，本次 TD read_sdc 未执行该循环；需适配显式语句并复核命中，现登记 OPEN。不得将这些数字解释为 W2 或 S2 单周期逻辑链故障，也不得据此直接签核异步路径。后级同步、束数据保持和 SDRAM 双相路径仍需正常 STA。

复核报告中正常路径：CTRL50MHz域最差+0.392ns/0端点（FIFO二级gray→pixel_x CE，17级、18.450ns）；PIXEL25.2MHz域+9.115ns/0端点；CTRL→MEM双相+3.502ns、MEM→CTRL+7.637ns。均为综合估算，未验证物理布线。

在另一次只读 `saved gate.db + 展开SDC` 核查中，数值为Setup+0.392ns/Hold+0.471ns、0/0，9时钟、coverage99.77%。**此数字仍不签核**：`ctrl_error_meta*`按合成别名还命中ctrl_error部分源寄存器，`rd_gray_w1*`还命中rd_bin[10]，`wr_gray_r1*`还命中wr_bin[10]，造成额外D/CE端豁免；精准范围OPEN。`fault_code_meta*`实际仅命中8个首级D端。已触发物理硬失败，不再继续实施约束修改；需后续裁定。证据 `sim/integration_lint/cdc_audit/`。

束数据MC4/3也发现同类合成别名问题：实际例外2040端点包含预期1024个updater/spectrum捕获端，以及额外1016个pixel域spectrum_hold移位D端。后者被不当地给予4拍，登记OPEN；不能声明源域移位链正常单拍STA。正确跨域1024条束数据例外的握手语义成立，报告最差Setup+58.054ns/Hold+0.732ns，但不能因此接受另外1016条例外。后续需使用实际门级精确目标名并逐端点重验。

首次 `gate.timing` 的 Constraint File 为空、仅 DeriveClock 50MHz、coverage 89.28%，−10.567ns/37端点来自默认时钟：**排除目标口径签核**。原因是 TD 对脚本中带双引号的 read_sdc 路径未真正载入；复核改用无引号 ASCII 绝对路径成功。原始报告与日志全部保留，脚本已修订并增加约束文件和关键时钟检查。

## 2. 与基座的可比面积

基座 `v9_display_20261004_final2/physical_build.log:1228–1244` 的门级数字为 LUT12363 / REG10687 / 9K26 / 32K1 / DSP4 / PLL3；本次门级 LUT 增加 **8843**。基座 place 前的 TD 冗余清理曾将逻辑 LUT8753→6023、seq10462→6170，最终 Routed 为 LUT8633 / REG6419 / 9K25 / 32K1 / DSP4 / PLL3。

因此不能把本次门级21206与基座布线后8633直接相减，或宣称本次最终物理占用一定为108.19%。目前既没有本次物理阶段的面积，也没有证明物理清理后会满足90%；依冻结门禁先停止并报告。基座的下降仅说明后续“固定 RTL 的物理资源实测”值得规格方裁定，不构成通过保证。

门级层级计数按 `lut+ripple` 对齐：加载链2672、标签行链430（合计3102，对方案目标3100超2）、状态存储26/10BRAM、扫描其余glue254、完整S2 2195/17DSP、W2 4418/1DSP。W2独立包4492也是Synthesized计数，W2本体未明显膨胀。原REG预算1544未计独立包端口IREG1025/OREG51；移入内部后相应谱束等成为内部寄存器，所以不能直接用1544投影集成REG。

## 3. 已实现的完整链

- 固定 `PCB.BMP` 的 TF SPI→FAT32→BGR标签解码→SDRAM写入；文件 CRC32 `47E2A01D` 与物理升地址标签 CRC32 `A1E4D4E1` 双校验后才开放 `label_ready`。实际 BMP 为 24bit BI_RGB、921654字节；614400字节指解码后的16bit标签，原黄金文件未改。
- 480行冻结区段表、512×32行缓存、BL8对齐读取、1024×32异步像素FIFO；从物理 bottom-up 图像还原 top-down 640×480扫描。跨度内部零标签保留，451行以下标签清零，底部常驻128柱由原显示链绘制。
- 既有三银行快照→1024bit稳定谱束与双同步通知→正式端口 W2→10个16bit真双口9K状态分片→正式 S2。W2全量652写、T1/T2次序、commit/done/ack保持冻结口径；初次完成加载、像素预填与状态提交后才启动完整扫描。
- 复用网络PLL原闲置C1/C3作为50MHz/180° SDRAM域；C0/C2/C4、网络应用和HDMI两PLL保持原配置。新增控制域复位同步及精确CDC入口约束。
- 加载/行流/扫描故障走主板数码管 `60000+8bit故障码` 与故障LED；无卡、CRC错误和读流异常可诊断。多位CTRL诊断码连续两个像素拍相同且非零才锁存。
- 修正任务副本S2的局部黄金差异：连续流光需满足 `len>=total`。独立JS黄金要求连线长完后才启用流光；正式端口、14拍S2延迟和黄金均未改，原上游S2文件未改。

## 4. 验证结果及实际源身份

| 验证 | 结果 | 证据 |
|---|---|---|
| 标签行链 | 921600像素词，2正常帧+1复位帧，逐位匹配BMP；延迟、背压、错beat/提前done/断供注入通过；交换标签/图像突变被杀伤 | `sim/stream_label/`、STREAM_REUSE_LEDGER.md |
| SPI/FAT32/SDRAM完整加载 | 13场景PASS：superfloppy、MBR、第2根扇区3正例与10故障；正例完整153600物理字、双CRC、3个BL8读、非法地址检查；模型协议错0 | `project/src/vendor/fdi_loader/tests/LOADER_VALIDATION_MANIFEST.json` |
| W2/T1/T2/S2扫描 | 8×300=2400主场景帧+3延迟ready帧；2404真实W2批、1567408写全部对拍；有效区状态读及RGB重定时738201600像素匹配 | `sim/w2_display_result.json` |
| 独立像素黄金 | 8场景各帧0/36/89/179/299，共40整帧、12288000像素，逐位0失配 | 同上、`sim/w2_display_rgb_gold.cjs` |
| 整帧预览归档 | 静音/中频299帧PNG，均由已对拍的独立JS黄金导出；重新读取PNG回量化307200个RGB565字完全一致，非实板图、非DUT直接dump | `sim/evidence/verified_rgb_manifest.json` 与两张PNG |
| 旧S2错误杀伤 | 恢复旧S2源精确SHA，在boot_low frame36/pixel89279出现expected27737/actual65535，测试退出1 | `sim/w2_display_failure.json`、`sim/logs/w2_display/bug_repro/` |
| 显示防御 | 快照收谱超时A1、FIFO缺拍A3、慢CTRL导致有效区写A2注入PASS；A2稳定采样延迟2像素拍 | `sim/w2_display_result.json` |
| lint | W2严格Wall仅Wno-BLKSEQ：0warning；新模块0warning；整体342warning逐项OPEN，其中既有S2 unused51项 | `sim/integration_lint/`，加密IP/物理primitive只验证接口桩连接 |

扫描台真实W2最大更新 **18276个50MHz控制拍，0.36552ms**，属于这组集成输入的实测最大值，未替代独立W2包最大值。加载正例 **27110610个50MHz拍，0.5422122s**，测试 STARTUP_CYCLES=32，默认启动等待参数未经完整计时实测。

所有TD编译源以 `SOURCE_MANIFEST.json` 绑定，SHA256 `dc18a2f274e9acc029436e6b2e77cd05225ff5a7ae763c864cda42c3b48b00f8`。扫描/状态/S2的12个production RTL/header，以及加载store+10helper，均与本次实际验证源逐文件一致。新验证只通过正式端口，不访问W2内部状态写口。

整体lint实际输入SHA256 `3da77aa64a9913139a34dde67ab35621311cef1e2d34a73c3cf05bad28f6a494`，49输入编译后SHA不变，其中47个生产源/include与TD清单逐文件匹配。342警告分解：边界桩193、S2 unused51、整体模式下W2 BLKSEQ6、其他应用/模块92；另行W2严格口径0warning。UDP/TEMAC/clientFIFO/HDMI/PHY及公开PLL/SDRAM接口桩边界见lint SSOT，未验证这些IP内部。

`SOURCE_DIFF.json` / `SOURCE_DIFF.patch` 保留逐文件差异：基座75文件中67不变、8在授权目标适配清单中变更、无删除；三银行快照、冻结W2三个源、PCB.BMP与row-span黄金SHA复核PASS。通信应用层其余源与基座相同；顶层只做显示域接线、时钟包装和故障显示。预检重新验证75个上游源与已验收位75959E68身份。

## 5. OPEN与剩余交付

TD本次原始日志94条WARNING/CRITICAL记录保留OPEN，包括既有加密IP/隐式声明、未使用端口/未驱动pin、ERAM init忽略等；模型测试不能证明加密网络/HDMI内部或物理I/O。状态表、行缓存及FIFO均在开放显示前显式写入；ROM实际映射/init仍须物理阶段复核。所有lint警告保留原始日志，不以全局豁免宣称零告警。

只读门级ROM复核已确认row-span常量保留：gate_view.v中2片EG_PHY_BRAM（低18位PDPW8K、高2位SP8K）的INIT/INITP重建512×20字，前480字与冻结case/区段资产一致、32默认字一致，0差异；ROMmux55未命中init忽略警告。此结论仅证明门级常量，物理/bit/板上未测。标量约束查询无丢失；S2状态读地址+29.163/+1.625ns、读数据+35.433/+3.181ns，8bit fault首级→sync为8正常STA端点。审阅SSOT `sim/integration_lint/cdc_audit/AUDIT.json` 状态OPEN/signoff=false，完整边界与哈希见同目录AUDIT.md。

本包无粒子、无W1、无柱顶连线、无TF真音频，未裁去其余冻结效果。043主线、副板7175ECC3、基座及已验收位均未改；未git提交或建立分支。

尚未完成：本次完整物理面积/布局布线0违例、SDC精准范围修复及重新签核（循环展开已完成，别名范围审阅暴露OPEN）、SDRAM/TF板级采样裕量、bit、BURN_INDEX流程、完整PCB静态与动态及底部128柱≥10分钟板测。**未出位、未登记、未代签验收。**

后续授权已执行：用户回复“授权固定 RTL 继续物理实测（推荐）”。保持全部RTL与冻结效果不变，仅展开原SDC的7条循环体，再执行TD物理探测，固定RTL身份由脚本逐文件守卫。探测在器件打包容量检查失败，按“超限继续停止”再次停下。此授权不包含RTL重构或删效果；下一步RTL/综合策略调整须规格方另行裁定，当前不执行。
