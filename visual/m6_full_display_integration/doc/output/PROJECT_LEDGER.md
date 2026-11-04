# M6-FDI 包内台账

2026-10-04，最终状态 **HOLD_PHYSICAL_CAPACITY**；本文件仅为本包记录，不修改根docs或052/043主线台账。

| 事项 | 记录 |
|---|---|
| 启动授权 | 读取并执行m6_full_display_integration/START_PROMPT.md |
| 一页评审 | 用户回复“确认按裁剪方案实施（推荐）”，固定PCB文件/640×480、网络PLL闲置C1/C3方案获准 |
| 副本实施 | 基座75源先复制；67保留、8目标适配、无删除。W2正式端口及黄金保持冻结 |
| 模型验证 | W2 2404批/1567408写、独立RGB黄金12288000像素、标签流921600词、加载13场景通过；边界桩与OPEN警告保留 |
| 首次门级 | 21206 LUT/16424 REG/42×9K/5×32K/18 DSP/3 PLL，Synthesized超90%，停止并报告 |
| 后续授权 | 用户回复“授权固定 RTL 继续物理实测（推荐）”，只适配SDC执行写法，固定RTL做物理探测 |
| 固定RTL守卫 | 61编译文件+2include+ADC共64项SHA一致；未重构RTL、未删冻结效果 |
| 物理实测 | TD冗余清理/放置/打包；PHY-9009要求5099 MSlice、容量4900，失败，再次停止 |
| 时序审阅 | 原单默认钟测量排除签核；展开SDC后的综合数值0/0，但CDC/MCP合成别名范围OPEN，未签核物理STA |
| ROM审阅 | 只读门级INIT重建与row-span源逐字核对；结果见cdc_audit，不能代替物理bit或板测 |
| 后续未授权 | RTL重构、综合策略调整、改变器件或裁冻结效果均未执行 |
| bit/BURN_INDEX/板测 | 无新bit、未登记、未烧录、未代签；BOARD_RECORD.md明确NOT_STARTED |
| 上游保护 | 052通信应用、三银行快照、043主线、副板7175ECC3、基座位75959E68及黄金资产未改；已复核SHA |
| 代码库操作 | 无git提交、push或分支操作 |

主报告：M6_FDI_INTEGRATION_REPORT.md；原始TD：td_run/synth1g 与td_run/place1；保护与差异：SOURCE_DIFF.json/patch；实测结构数据：MEASURED_GATE.json；SHA证据索引：EVIDENCE_INDEX.json。恢复实施须规格方针对实际物理容量失败与精准约束OPEN另行裁定。
