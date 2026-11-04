# M6-FDI 0x46 真卡排查范围

依据：主人 2026-10-05 追加实测及 `doc/output/BOARD_FAULT_0x46_20261005.md`。原 6B810152 硬件 FAIL；TF 卡、引脚、电气通路已有独立核验，不重复修改卡布局。

首轮上板候选：A2，两级 MISO 恒等缓冲（原四级）+ ERROR 前一拍只读状态快照。零缓冲 A0 未烧录，实测余留 2 条 MISO Hold 违例（−0.532ns），保留过程证据，不出具正式位。

新增诊断引出 store state/sector_number/bytes_seen/write_index/mem_busy/write_pending，init/command/byte 内部态、reader 等待态及 SDRAM 引擎态。五个驱动副本仅可逆地增加只读端口，不改功能正文；不改 SPI 速率、采样、SDRAM 时序、CRC、超时、W2/S2、效果或保护上游。功能加载改动只允许缓冲深度 4→2。

仍执行物理容量 <4900 MSlice、最终 Setup/Hold 0/0、精确 CDC、ROM INIT 和原 lint 告警登记。模型用于软件回归，不代签真卡。原 R2 封存证据与位文件保留。

真卡门禁：完整 PCB 线稿出现且稳定至少 10 分钟，记录 KEY1 复现；失败则回传错误码和 P1..P7 十进制读数。结果回来前不继续功能迭代。不以单次成功配置唯一归因于 MISO，诊断引出也会改变物理布局。BURN_INDEX 仍由主人/规格方登记。
