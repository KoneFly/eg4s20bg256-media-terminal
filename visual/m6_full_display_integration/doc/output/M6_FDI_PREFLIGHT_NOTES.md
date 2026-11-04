# M6-FDI 只读核查证据

日期：2026-10-04。此记录是RTL实施前的一页评审证据，保留当时预算与计划；不代替合体测量或验收。后续用户确认后已实施和验证，并授权固定RTL物理探测；最终打包MSlice5099>4900，当前HOLD，见[M6_FDI_INTEGRATION_REPORT.md](M6_FDI_INTEGRATION_REPORT.md)。上游资产未修改。

## 授权及适用要求

当前用户明确要求读取并执行本包；本包是本轮采用的工作要求。既往自主判断授权仍适用于日常实现选择，但当前启动包第3.1节明确设置唯一中途确认点：**“先出 1 页，规格方确认后实施”**。因此先完成具体方案与资产核对，再等待此项确认；超预算停止来自同节“超预算即停、报告待裁定，不得静默裁规格”。不是另加的审批流程。

范围依据 START_PROMPT.md 及项目 DECISION_LOG D-15/D-16/D-17/D-18；新包授权在独立副本中集成并出位，覆盖此前W2独立交付的“不集成”阶段边界，但不授权修改052现场树、043主线或副板7175ECC3。本包范围不包括粒子、W1、TF真音频及043合体。PORTING_PLAN/INTERFACE_CONTRACT中历史粒子、转场及043图像通道条目按本包明确边界适配，不能扩大任务。

## 资产身份与黄金

运行 scripts/preflight.cjs，全部75项基座SOURCE.sha256记录与src文件一致。基座位完整SHA：`75959e68b425de7a36ee937949c683b956d90164ea72c68e2bbcd40b6d5d5d1b`。W2三个活动RTL文件均与当前td_result_mc.json身份一致，保留no_particles_v2黄金和冻结端口。

PCB.BMP为24bit BI_RGB、640×480、正高度（底向上）、offset54、921654字节；原烘焙工具 prototype/bake_label_map.cjs 与 PORTING_PLAN §2.2/S1 一致。启动包614400B是16bit数据量，不是该文件长度。不改源图或ROM；解码为RGB565时只有纯位截断，禁止缩放、调色或插值。文件CRC32 `47E2A01D`，解码正向标签小端CRC32 `9E9CE1C5`，物理升地址（底行优先、每个标签低字节在前）CRC32 `A1E4D4E1`。读回校验须明确按视觉扫描或物理升地址取数，并选用对应CRC，不能把文件CRC、两种标签CRC互换。固定加载按BMP文件像素顺序递增写入，扫描端以479-y反转行地址，等效原加载链两次行翻转后的物理布局。

rom_row_span.hex所有480项与BMP标签的非零首尾吻合。编码有[11:10]两位留零，不能按三个紧挨10bit字段解码。n为首尾之间连续宽度，包含内部零标签，不是非零计数；总184827像素，均值385.05625，范围39..513。前451行span共180318像素。BL8读应先将word0=(x0>>1)&~7、word1=(x1>>1)|7对齐，不能把SDRAM块内wrap当连续线性beat；前451行共93456个32bit字，单行最大264字。这些是离线容量/请求量，不是带宽或行填充拍数的实测。

## 资源证据与尚未核定项

路径均以项目根 `D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/` 为基准；这些上游文件只读引用。

| 证据文件 | 位置/事实 |
|---|---|
| iccoder_workspace/tasks/task_052_ethernet_pcm_link/td_run/v9_display_20261004_final2/eth_udp_m6_master_top_route.area | 11–27行：8633 LUT、6419 REG、25×9K、1×32K、4 DSP、3 PLL；144–146行：u_scan=1125 LUT，其中u_renderer=917 LUT、409 seq、2 BRAM、4 DSP；不能把余208 LUT都扣成updater |
| 同目录 eth_udp_m6_master_top_route.qor | 6–11行：Setup+1.153ns/Hold+0.003ns，0/0违例；仅基座结果，不能移作新工程结果 |
| iccoder_workspace/tasks/task_045_pcb_pixel_renderer/td_run/area_report.txt | 19–30行：完整S2真实#lut2228、REG600、9K8、32K0、DSP19；Total_luts1148不是本包预算口径 |
| visual_workspace/rtl_handoff/pcb_dynamic_layer/sim/td_result_mc.json | W2=4492 LUT、1544 REG、32K1、DSP1；综合级50MHz+2.909/+0.621ns，不代表集成后物理时序 |
| iccoder_workspace/tasks/task_052_ethernet_pcm_link/td_run/v10_audio_20261004_a/eth_udp_audio_master_top_route.area | 160–175行：SD初始化302、扇区读202、回放825、FAT扫描1088、文件流525 LUT；合计2942 LUT、1655 REG、4 DSP。是既有树层次参考，不是新独立模块测量 |
| iccoder_workspace/tasks/task_043_mainline_integration/td_run/verified.area | 108–118行：loader3342 LUT减resampler1328=2014，REG1550减529=1021、BRAM15减8=7、DSP8减2=6；7 BRAM未按9K/32K细分，不作细分实测声明 |

S2 renderer源与052 vendor完全同SHA：`413f8996098d7208b219fdf06e504dd344dadfc72dc81bbe5c251b44b5ebea49`；state_mem同SHA `1f13753053a8e5cff5b488e9da60943e78b7837e2f69b84460fc1f626cc6a2f4`。但基座in_label=0、ov_on=0和常量状态使逻辑被剪枝，不能把其917 LUT/4 DSP当完整线稿显示成本。

不扣任何基座路径、再叠完整S2+W2的保守已知底数是15353 LUT/8563 REG/33×9K/2×32K/24 DSP/3 PLL；尚不含外部T1/T2及标签加载/扫描，故剩余额度2287 LUT/2 DSP不是可行性证明。一页方案的替换投影14436 LUT/8154 REG/31×9K/2×32K/20 DSP/3 PLL则以旧S2被完整替换为前提；新增3100 LUT等额度仅为设计目标。REG层次seq与全局#reg含映射边界差异，实际相减也须用整体TD复核。全部资源最终只以新工程报告为准。

完整直接复用参考总19392 LUT及30 DSP，分别超过90%和物理DSP容量。不得以“基座余10967 LUT”忽略完整S2解除常量后的增加、存储及标签链。固定文件/尺寸裁剪尚未实施，尚无可达预算的实测保证；状态HOLD等待具体方案确认。外部状态表BRAM映射、各RAM宽深限制/读取延迟以及标签每行耗时仍需TD与集成验证。

## 引脚和PLL

基座 src/constraints/eth_m6_master.adc 35–48行RGMII、85–90行HDMI/DDC；全部46项显式LOCATION无重复。route.area 47–54行自动HDMI负端为C2/G6/F2/D1，与拟用TF A14/B14/A13/A12交集0。043 constraints/m1a_top.adc 52–55行可复用TF四脚，保持LVCMOS33和输出驱动8。SDRAM为内部EG_PHY_SDRAM_2M_32（043 rtl/sdram_frame_buffer.v:199），无外部SDRAM引脚。

官方先例：`D:/Download/嵌赛fpga_安路/01_官方资源/例程_HX4S20C/lab_ex_6_tf_sdram_hdmi/top.adc`是TF+SDRAM+HDMI，没有Ethernet；其HDMI正端K1/F5/E3/B3与052不同，不能照抄。lab_ex_4_tf_sdram_etnernet_pc/par_ph1demo/ph1_constraints/ph1_demo.adc另证TF+SDRAM+Ethernet同TF四脚及RGMII12脚。静态引脚核查通过仍不能代替新工程TD bank合法性与上板。

基座src/vendor/udp_base/ip/pll_gen.v:69–88为网络PLL C0/C1/C2/C3/C4，VCO1000MHz；src/rtl/v9_udp_m6_master_top.v:24、33、51证明实际只使用C0网络125MHz和C4 125MHz90°；其余出口无消费者。建议只将C1/C3设DIV20/CPHASE19、9为SDRAM50MHz双相，保留C2既有分频及VCO/反馈/C0/C4。043 rtl/sdram_clk_gen_50m.v的同DIV/PHASE提供参数依据，新增派生时钟仍须STA；不假定直接反相板载时钟是已验双相方案。不新增第四PLL，不修改HDMI两个PLL/PHY。

## 集成防御及验收口径

052四步无SDRAM/标签像素FIFO，需在副本新增窄链，而非误认为已有可接标签tag。043/056 async_pixel_fifo是寄存读出：rd_en且非empty接受后数据更新，消费适配须按同步语义取样，label/image从同一32bit词同时采样；深度1024、AFULL_MARGIN36保持。标签单项行缓存仅在行发布/消费确认之间锁定，填好该行再生产，禁止未填好却用0冒充正常标签。FIFO空/迟供给要锁存错误并防错位。commit同步及ack接收器独立于in_valid、label_ready和显示开放运行，首批state_committed由commit同步置位后与label_ready共同开放S2，防止启动环依赖；S2 barcache在像素流关闭时仍接收首批W2写口。状态表同步读口自由运行，无需停钟，消隐写约束是避开有效消费及flush。

原v9_spectrum_snapshot三银行、CRC/旧包/500ms离线/epoch机制保持源码不变。128字节同步读取到稳定1024bit向量，经toggle握手让W2在消隐锁存。原v=515/h=0至下一帧输入v=33约1.365ms；W2已测最大19703个50MHz拍约0.394ms，集成还须测快照、CDC、写尾及commit裕量。W2写口同时送pcb_state_mem和S2 barcache；T1 512/T2 140顺序和commit/done保持，像素域确认commit后才ack。不得绑ack常量或在epoch改变时自行清W2以改变黄金。状态表写仅在有效像素读/flush之外，首帧就绪条件包含标签完整校验和第一批状态提交。

标签加载失败、CRC错误、行供给失败均要有可定位LED/数码管码，并保持HDMI扫描时序；正式状态码待实现文档登记。启动加载/校验期间不读显示标签；运行期标签读优先于诊断，全局刷新优先。缺TF、损坏BMP、簇链异常、刷新竞争、epoch改变、副板重启、静音/衰减、首末像素/行及满640×480尺寸均纳入集成判据。

设计保持KISS/YAGNI：固定单文件和单屏，不搬入轮播/音频控制；DRY：复用已验卡协议、簇链、SDRAM底层和冻结S2/W2，而不是重写协议；职责分离为加载、行供给、帧更新和像素渲染，经正式端口及握手交接。搬用只在任务副本进行、来源登记在本包内部台账，根docs只读。所有结果分开注明综合级、物理TD、板测；告警如实OPEN，不代签验收或BURN_INDEX。

确认后本包继续至集成工程、逐文件diff、TD、bit和上板记录；超预算按启动规则停止待裁。新工程验证按本包明确要求使用Verilator/冻结黄金，不引用历史项目更宽松条款省略本包要求；未上板不得写硬件PASS，最终10分钟板测仍需主人配合。
