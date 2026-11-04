# M6-FDI 标签加载链复用台账

2026-10-04。全部上游先复制到本包 `project/src/vendor/fdi_loader/` 后修改；上游未写入。原始 SHA256 见该目录 `REUSE_SOURCE.json`，当前源身份另登记 `LOADER_SOURCE_MANIFEST.json`。所有辅助模块加 `fdi_` 前缀，避免与现网络/未来043合体的模块名冲突。

| 源资产 | 任务副本 | 适配 |
|---|---|---|
| 052 `vendor/audio043/sd_init_sequence.v` | `fdi_sd_init_sequence.v` | 卡初始化协议不变；去未使用快分频输入；慢分频63、2048轮询上限。保留既有SDHC假设，未读CMD58 CCS，不声称已测容量类别 |
| 同目录 `sd_cmd_transactor.v`、`sd_spi_byte_engine.v`、`crc7_calc.v` | 相应 `fdi_*.v` | 初始化命令、CRC7、CS、SPI行为保持；显式无损位宽及调试出口lint标注 |
| 同目录 `sd_spi_sector_reader.v`、`mx_byte_engine.v` | 相应 `fdi_*.v` | 直接SPI扇区读、CRC16检查、超时/令牌错误保持，快分频1；不使用sector replay缓存。rx_shift仅保留实际消费的7位，最后一位与输入组成8位输出，时序不变 |
| 同目录 `fat32_volume_scanner.v` | `fdi_fat32_volume_scanner.v` | 仅根目录短名 `PCB     BMP`；保留superfloppy/首MBR FAT32分区、BPB、普通文件属性检查、连续16扇区根扫描窗口。改为流式字段捕获，去512字节多读口缓存和PIC/WAV槽；簇地址/几何使用逐拍移位，无乘法DSP |
| 同目录 `fat32_file_streamer.v` | `fdi_fat32_file_streamer.v` | 保留簇链范围/自环/计数上限、提前EOF与文件结束后EOC检查；SPC验证为二次幂，簇LBA乘法改为多拍移位；去未消费next_cluster镜像和FAT保留高4位 |
| 043 `rtl/sdram_cmd_engine.v`、`sdram_refresh_timer.v` | 相应 `fdi_*.v` | 命令、BL8、刷新及DQ_LAT结构保持；位宽比较显式化，去未用op_row。50MHz参数T_INIT10000、RP/RCD2、WR/MRD2、RFC4、CAS3、DQ_LAT1、刷新781拍 |
| 043 `tb/EG_PHY_SDRAM_2M_32.v` | `tests/EG_PHY_SDRAM_2M_32.sv` | 仅仿真；添加default空命令分支消除CASEINCOMPLETE，已有行为不变，不列入TD |
| 052 `tests/reference_audio/sd_spi_card_model.v` | `tests/sd_spi_card_model.sv` | 仅SPI引脚假卡；改本地测试镜像路径；为Verilator统一模型采样赋值方式，更新cbuf采样为已经包含当前位的sh_reg，避免重复移位；不列入TD |

新增 `project/src/rtl/fdi_label_store.v` 单独负责启动控制、固定BMP54字节严格检查、BGR纯截断、两标签打包写、文件CRC32/物理标签CRC32、只读burst服务及故障锁存。文件顺序写物理字址0x40000..0x657ff；底行优先，每字偶x低16/奇x高16。文件CRC为47E2A01D，物理升字址、每字低字节先的标签CRC为A1E4D4E1。一个逐bit CRC核复用，启动读back按8字缓存后串行处理，运行期不写标签。

## 接口与故障码

正式端口保持 `IMPLEMENTATION_INTERFACES.md`。label_ready仅完整载入、文件CRC及全量SDRAM回读CRC成功后为1。运行期仅接受范围内BL8对齐读请求，busy期间不接下一请求；每burst8拍数据，rd_done为事务完成。刷新由命令引擎硬优先；错误锁存至复位，label_ready关闭。

| 错误码 | 意义 |
|---|---|
| 80..87 | 卡初始化错误，低3位沿用初始化器 |
| 10 | SPI扇区读/CRC16错误，由挂载或文件链上报 |
| 20/21/22 | 启动签名/BPB/PCB文件缺失 |
| 23/24/25/26 | FAT自环或文件结束未EOC/簇范围/提前EOF/簇链计数上限，保留既有语义 |
| 40 | 固定BMP头字段错误 |
| 41 | 文件CRC32失配 |
| 42 | 文件/像素/写入字数不符 |
| 43 | 文件字节不连续、CRC核未空闲或写待提交槽溢出 |
| 45 | 运行期请求非BL8对齐或越过标签区域 |
| 46 | 上电全流程超时，默认10秒 |
| 47 | 运行期存储事务超时，默认20毫秒 |
| 48 | SDRAM全量物理标签CRC32失配 |
| 49 | 校验burst字数/类型或状态异常 |

## 验证与限制

RTL严格lint使用Verilator5.032：`--lint-only --timing -Wall -Wno-BLKSEQ`，无告警；仅故意不消费的复用底层调试出口有源内局部UNUSEDSIGNAL说明。测试模型的独立binary构建允许模型位宽告警，保存在tests/build.log，不作为RTL无告警声明。

`tests/gen_fixture.cjs`只读引用黄金PCB.BMP，生成4096扇区FAT32镜像、226个连续文件簇和独立纯截断物理字黄金。`tb_fdi_label_store.sv`从SPI引脚驱动真实初始化、扇区读、FAT扫描/文件链和双相SDRAM模型，未替换被测loader内部接口。成功台逐一核对153600个物理字、两类CRC、三个BL8请求、非法请求及协议模型错误计数。已启动的13个场景全部完成，日志如下；日志、测试源及RTL身份登记于`project/src/vendor/fdi_loader/tests/LOADER_VALIDATION_MANIFEST.json`。

| 场景 | 注入/布局 | 结果 | 实测50MHz拍数 |
|---|---|---|---|
| 0 | FAT32 superfloppy，根首扇区PCB | PASS，全量物理字与3个BL8校验 | 27110610 |
| 1 | BMP像素字节翻转，SD块CRC随模型重算 | PASS，错误41文件CRC | 21504209 |
| 2 | BMP宽度字段翻转 | PASS，错误40头字段 | 173563 |
| 3 | SDRAM内容注入单字翻转 | PASS，错误48标签CRC | 27110610 |
| 4 | PCB根目录项缺失 | PASS，错误22 | 183477 |
| 5 | SD首文件块CRC16错误 | PASS，错误10 | 183484 |
| 6 | 卡无响应 | PASS，错误83初始化器超时 | 31602882 |
| 7 | 首文件簇自环 | PASS，错误23 | 267669 |
| 8 | 首文件簇提前EOC | PASS，错误25 | 267669 |
| 9 | 下一簇为非法簇1 | PASS，错误24 | 267669 |
| 10 | 文件末簇未EOC | PASS，错误23 | 21504208 |
| 11 | 首MBR FAT32分区位于LBA16 | PASS，全量物理字与3个BL8校验 | 27121133 |
| 12 | PCB位于第2根目录扇区 | PASS，全量物理字与3个BL8校验 | 27121134 |

故障结果覆盖上述具体注入，不声称所有超时、BPB、簇链上限或硬件故障路径已穷举。

主成功台在测试STARTUP_CYCLES=32时就绪耗时27110610个50MHz拍，约0.542212秒；含2029次SPI读、34385次SDRAM刷新。实际默认STARTUP_CYCLES=500000，默认首帧就绪拍数尚待整体测量，不把测试参数结果冒充默认值。

既有FAT扫描边界明确保留：只检查第一MBR分区和首根簇起连续16扇区，不支持LFN或任意碎片根目录簇链；文件数据簇链仍按FAT遍历，并保留错误及计数限额。SDHC为既有假设。行为模型不是硬件验收或SDRAM物理时序证据；面积/DSP/Setup/Hold交根统一TD后登记，不声称已达3100 LUT额度。

`tests/`及其中obj_dir/镜像/日志仅用于仿真，**不列入TD源表**。本加载链综合源为fdi_label_store.v及vendor/fdi_loader根目录10个.v文件。

## 硬门禁冻结

`synth1g`整体面积保持[gate.area](../../td_run/synth1g/gate.area)的Utilization Statistics口径：21206 LUT，超容量19600及90%门禁17640；DSP18。时序采用既有`gate.db`只读重载目标`eth_m6_master.sdc`后的[checked.qor](../../td_run/synth1g/checked.qor)：Setup -5.044ns、7个违例端点，Hold +0.471ns、0个违例端点；[checked.timing](../../td_run/synth1g/checked.timing)列出9个时钟、STA coverage 99.77%、Confidence Synthesized。整体门禁仍失败，按启动包停止production RTL修改，等待规格方裁定；这些是完整FDI综合级测量，不能解释为本加载链独立面积或布线后签核。

首轮`read_sdc`双引号路径未成功加载；原始`gate.qor`/`gate.timing`的Setup -10.567ns、37违例是单默认时钟口径，不作为目标SDC门禁依据。原始报告保留，修订仅引用[check_timing.tcl](../../td_run/synth1g/check_timing.tcl)及上述checked证据；未重综合、未改RTL。`checked.qor`的`#luts=15068`是LUT Statistics口径，门禁仍使用`gate.area`的Utilization `#lut=21206`。

停止后完成已经启动的故障台和本证据台账。逐文件SHA256核对`synth1g/src/rtl/fdi_label_store.v`及`synth1g/src/vendor/fdi_loader/`10个综合helper，均与当前project源及`LOADER_SOURCE_MANIFEST.json`一致（11/11）。主模块冻结SHA256：`dcb4d4adfea54a1ec9e98fde9a0b46b09372a95ded40138ca9e0f35a09baca8e`。测试源后续变更仅增加场景/修正测试模型与预期，未形成另一版production RTL；`LOADER_VALIDATION_MANIFEST.json`保存三方逐文件比较结果。行为仿真通过不覆盖已失败的整体资源与STA门禁。
