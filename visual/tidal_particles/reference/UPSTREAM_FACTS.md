# M5 上游事实快照（2026-09-24）

| 资产 | SHA256/现状 | 用途 |
|---|---|---|
| Task030 `rtl/spectral_ridge_renderer.v` | 53995D1EBE1EE866F89AFCB19507852758220D3644E54739B3038D69B8AEA22C | M4端口/内容对照，模块17/17、TD 584LUT/110REG/1DSP，未据此宣称上板 |
| Task014 `rtl/energy_envelope.v` | C8745087C2A43D7201E3CBC3578A4CEECA86D97D98648FC138269E32CBDE2A16 | 8路平滑包络 |
| Task024 `rtl/audio_band_energy.v` | AB569EFA00B9B30B14BF344B5147CCA7582BFB79AC2CDB5703D4CA81E1DC858B | 真音频八段分析，4DSP，输出64位 |
| Task036 P1 `rtl/m1a_top.v` | B14DACE841460D8B0CD4B175554B734C2FE5D1A6EA34296092909B63AFCD29D3 | 主线临时资源底数；P2/P3继续变动，不能视为最终SHA |

Task036 P1_AREA_REPORT.md实测12684 LUT、7004 REG、7054/9800 slices（71.98%）、14DSP、45BRAM9K、SWNS +0.099ns、0违例。M5_KICKOFF明确P1腾出量不得预支、模块级可并行、板级集成需036稳定且M4先行。

参考概念：Sonic Topography的频段/涟漪、Mineradio-paused的粒子舞台、FE-Monster的温暖场景。未复制三仓库源码、图片、品牌或UI；交付效果的数学定义以本任务行为规格为准。
