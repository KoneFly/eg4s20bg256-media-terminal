# M6-FDI 工程快照

2026-10-04，**HOLD_PHYSICAL_CAPACITY**。本树是052第四步75959E68基座的任务副本，集成完整固定PCB标签图与W2/S2链。源已完成模型验证；TD门级LUT21206超限，用户随后授权固定RTL物理探测，实际打包需要5099个MSlice超过器件4900，未完成布局、未布线、未出bit、未上板。

方案确认与固定RTL物理探测授权均已执行；超限后停止实施的要求仍适用。下一步RTL/综合策略调整须规格方另行裁定，不能从本文推断授权。

入口：`src/rtl/v9_udp_m6_master_top.v`（module eth_udp_m6_master_top）。正式源列表与校验见 `../td_run/synth1g/SOURCE_MANIFEST.json`；include需提供 `src/vendor/fdi_stream/fdi_row_span_rom.vh`；TD采用ASCII临时目录，脚本仅生成本任务结果。`src/vendor/*/tests`仅供仿真，不参与综合。

`assets/PCB.BMP` 与 `assets/rom_row_span.hex` 是未修改的黄金资产副本。TF固定8.3文件名PCB.BMP；加载成功后才开放像素流。资源、时序复核、未验证项、复用边界、逐文件diff及板测状态见 `../doc/output/M6_FDI_INTEGRATION_REPORT.md`。

所有上游只读；未改通信应用层、三银行快照、副板、043主线或已验收位。W2三份源与冻结多周期包逐字一致。S2任务副本增加 `len>=total` 流光门限，与独立JS黄金对齐。
