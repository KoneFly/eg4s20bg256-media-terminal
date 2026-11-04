# 上游接口核对记录

日期：2026-09-11。项目根：`D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal`。

只读源目录：`iccoder_workspace/tasks/task_011_hdmi_video_white_screen_fix/rtl/`。

| 源文件 | 实际端口/事实 | SHA256 |
|---|---|---|
| video_timing_data.v | I_clk、I_rst（高有效）、O_hs/O_vs（低有效）、O_de；800×525，有效区640×480 | 13538EBC220E63FE677F466A8EECAC3C84198DDA3587445F61C3453B66108230 |
| video_source_b_fixed.v | I_clk,I_rst,I_vs,I_de,axis_s_ready；输出axis_s_user/valid/last/data[23:0]；无外部像素输入 | 5646044CF4427F3BFF4A1B2DA6F328910642FDDB5195C6DC5448CB3A3A719493 |
| hdmi_video_fixed.v | 时钟pixel_clk/serial_clk；时序v_hs/v_vs/v_de；像素输入24位；顶层只有clk_50m/rst_n输入 | 89CDE20144C8F44D03D76A1D59F7BFB279BC3E8BA85F398659B068EE495881BC |

以上指纹仅记录当前读取版本，不证明任意后续修改等价，也不替代上板证据。上板状态依据视觉资产清单；此次没有重新烧录验证。

时序布局：水平sync96、后肩48、有效640、前肩16；垂直sync2、后肩33、有效480、前肩10。保持现有基线。

真实源在 `I_de && axis_s_ready` 时推进列计数；视觉模块依据DE推进，两者在ready低时语义不同。主线必须冻结接收前提或缓冲契约，本任务不假定ready永远高已经获得实验证明。

黄金表 `eight_bars_geometry.json` 与视觉工作区 `golden/eight_bars_geometry.json` 为同一版本快照；修改需规格方审阅并同步，执行方只读。
