# M6-FDI 第二轮交付报告

2026-10-05。**软件门禁通过，候选 bit 已生成；上板验收待主人配合。** 标签加载改为受控 TF 固定 LBA，冻结效果、W2、S2及其余生产 RTL 保持字节一致。最终物理占用 **4717/4900 MSlice（96.27%），正余量 183**，通过≤4850目标；4410/90%争取项未达成，不作为已批准底线的失败。

## 原生 TD 实测与口径

| 指标 | 第一轮 | 第二轮正式综合 | 第二轮最终布线/出位 |
|---|---:|---:|---:|
| LUT | 21206 | 19670 | 16297 |
| REG | 16424 | 15547 | 11418 |
| ERAM9K | 42 | 44 | 43 |
| ERAM32K | 5 | 5 | 5 |
| DSP / PLL | 18 / 3 | 18 / 3 | 18 / 3 |
| MSlice | 5099，打包失败 | 不以LUT折算 | 4717，余量183 |
| Setup WNS / 违例 | 原约束有别名问题，不能签核 | +0.392ns / 0 | +0.889ns / 0 |
| Hold WNS / 违例 | 原约束有别名问题，不能签核 | +0.459ns / 0 | +0.027ns / 0 |

综合数据来自 `td_run/checked2d/gate.area` 的原生 Utilization，最终数据来自 `td_run/bit2_final/route.area`、`route.qor`、`route.timing`。MSlice数取最终物理网表EG_PHY_MSLICE实际计数；选中放置place2d的初次打包数4731，放置优化后4717，最终优化可继续变化。容量门禁按物理MSlice评定，不把映射LUT或混合统计Total_luts当成物理容量。

TD新综合流程的首次read_sdc存在未生效现象，正式综合签核为导入gate.db、清空并重读显式production.sdc后的checked2d；早期默认时钟报告排除。打包后逻辑FF名发生变化，place2d的原逻辑约束时序亦排除；placed_checked2d起使用物理端点约束。中间负裕量、失败修复尝试全部保留，只有本报告绑定的最终运行参与签核。

## 加载链与受控卡

RTL只读LBA64–1864，共1801次CMD17，固定磁盘BMP为640×480×24bit、921654字节，解码后的16bit标签为614400字节；末扇区54字节有效、458字节补零。文件CRC32 `47E2A01D` 与升地址16bit标签CRC32 `A1E4D4E1` 保持冻结值，扇区CRC16亦保留。MBR、FAT遍历、目录和簇链分支从标签生产链删除；原两份FAT RTL保存在reference/round1_fat32，不参与59份HDL编译。

受控PCM分区从LBA2048起，数据区LBA6144起，FAT32根目录WAV1.WAV–WAV4.WAV沿用052第五步契约。标签区与PCM分区无交集。PC工具 `scripts/make_controlled_card.py` 创建新128MiB镜像并验证双FAT和各素材完整簇链，拒绝覆盖/直接设备写入。完整制作、写卡和读回步骤见 `CONTROLLED_TF_CARD_V2.md`；label_only.img仅供标签测试。另已只读引用052真实短素材，产出 `sim/round2_card/label_pcm_short_real.img`，四槽10.1/12.2/14.3/16.4秒，镜像SHA `db41b9c551ccde1c0ecdad878e997357ff9443f56ff095096e69407933f3a5f0`；重建素材及上游SHA复核均通过，未写实体卡。8项工具正反例仍为合成数据，真实镜像验证单独登记；正式长曲布局与052另行统一。

读回CRC缓存改用已有16bit状态RAM，采用显式一拍读等待。MISO增加4个保留的EG_LOGIC_BUF身份缓冲以满足输入最小延迟；没有增加采样寄存器或改变SPI拍序。该物理延迟由最终TD STA验证，Verilator模型只验证逻辑恒等。

## CDC 约束范围

显式约束取代foreach/get_regs别名。门级52个首级FF D端点映射为最终101个物理数据端点，另有1024个W2谱输入D端点使用MC4 setup/MC3 hold并显式-end（CTRL接收时钟）。物理LUT/FF合并端点采用捕获时钟加through数据引脚过滤，避免同名扇出扩大到源域D/CE。

最终逐端点查询1125项通过；2048条MCP规则各支配1条路径，实际端点集合恰为1024项；像素域spectrum_hold移位寄存器误豁免为0、源域D/CE别名误豁免为0，**本轮约束范围无别名OPEN**。基座既有PHY↔clk50及按键例外保持。逻辑SDC与实际物理SDC分别封存，SHA见ROUND2_MEASURED_GATE/最终SOURCE_MANIFEST。所有物理约束使用实际捕获端点，没有放宽TF输入max10/min0及输出max2/min0预算。

## 验证、证据与告警

本轮11个真实SPI模型/SDRAM模型加载场景全部通过，含正常全307200像素、双CRC失败、无卡、首尾扇区CRC16错、错误LBA位置、慢token、非对齐及越界读取；正常启动实测24863814个50MHz控制拍，测试STARTUP_CYCLES=32、BOOT_TIMEOUT_CYCLES=60000000，不能冒充生产默认启动等待实测。正常与慢token场景均准确读取1801扇区。

61项冻结RTL/include/ADC字节身份检查通过，沿用第一轮2404批W2/1567408次写、2403显示帧/738201600像素对拍、40独立JS黄金帧/12288000RGB像素证据；未把旧FAT加载13用例列为本轮受控链验证。W2最大更新18276拍是复用的第一轮实测。加载链严格lint及W2严格lint均0告警；全顶层接口lint0错误、342告警OPEN，IP内部/物理模型不由接口lint代签。PC卡工具8项正反例通过。

最终路由ROM INIT解码512字逐项符合冻结行区段表，0不一致；未声称位文件读回或实体板ROM已验证。75份只读基座源身份、原基座bit、独立W2、黄金BMP/行表均复核通过；052/043/副板及已验收bit未修改。54个实际外部pad无冲突，TF A14/B14/A13/A12核对通过；SDRAM S系列为内部专用引脚。原始告警详见ROUND2_WARNING_REVIEW，不因0/0时序而销项。

## 位文件与后续验收

候选位：`deliverables/M6_FDI_R2_20261005_6B810152.bit`，636626字节。

SHA256：`6b810152e09eef36138e0ce8979712609a0828b18bf93de2b623fba79929b030`。

出位由通过容量、最终0/0、CDC和ROM审计的route.db生成；身份链见 `deliverables/ROUND2_BIT_MANIFEST.json` 与 `ROUND2_EVIDENCE_INDEX.json`。主板P7沿用原显示位ID，不能区分该新位，烧录必须按完整SHA识别；副板7175ECC3保持。外部BURN_INDEX由主人/规格方登记，本包仅归档候选位，不代签。

推荐后续先制作含真实PCM的受控卡并读回验证，再配合主人烧录本候选位，核查上电线稿、频谱动态、底部128柱、无卡/损坏卡诊断及连续≥10分钟稳定性，按ROUND2_BOARD_RECORD填写。当前未写实体卡、未烧录、未上板；TF真音频应用层/043合体仍不在本包范围。容量已达到本轮目标，后续优先硬件验收，不为争取90%再改冻结效果。

## 重现

保留全部运行脚本、Tcl、源快照、DB、原生报告和审计。实际DB链（新到旧）：bit2_final → hold2h_clock → route2h → route2g → placed_checked2d → place2d → checked2d → synth2d；放置种子与布线努力级别记录在各SOURCE_MANIFEST/run.tcl。每一步使用新Tag拒绝覆盖；`scripts/run_round2.ps1` 完整实现门禁。普通自动buffer Hold修复在>90%占用时会跳过，EG4不支持尝试的pre-route hold phys_opt；本轮以保留MISO缓冲和最终原生clock_opt实测闭合。该流程遵循单一受控读取路径、复用既有RAM/PLL，不增加通用文件系统或预留新效果。
