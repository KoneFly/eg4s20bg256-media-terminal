# 行链复用与验证记录

本包 `project/src/vendor/fdi_stream/fdi_async_pixel_fifo.v` 由只读上游
`iccoder_workspace/tasks/task_043_mainline_integration/rtl/async_pixel_fifo.v`
复制后适配。复制时SHA256为 `8692b95e25d598d0c13807007a96ac2979d96bc98bcd5c7f46889d2a245579e2`。
适配仅为独立模块名、1024×32数据宽、AFULL_MARGIN36、跨域同步标记与至少640词首帧预填标志；
保留双域复位、灰码指针、满/空判断与寄存读取语义，未改上游。

`project/assets/rom_row_span.hex` 原资产SHA256为
`2399851ce9498039af59ae7bd5f2a7e2b32fb3a7b2c2c687ef1804d677d9b4cd`，文件未修改。
固定480项均非空，生成 `fdi_row_span_rom.vh` 纯case边界查表（保留x0/x1各10bit）；
不使用 `$readmemh` 或ERAM初值，避免TD eram_init关闭时标签区段失效。
生成表必须与原ROM逐行一致，TD须加入fdi_stream包含目录。

控制域错误码：31=像素空读或未ready读；32=区段ROM边界非法；33=beat地址/数量非法；
34=burst提前/错误完成；35=burst响应超时；36=状态机非法状态。错误均锁存到复位。
pixel_ready独立于pixel_take，先达到至少640词预填，再经像素域两级同步开放；
pixel_valid与FIFO寄存读输出同拍，欠载不输出伪造像素。

新增CDC入口（以stream实例前缀补全）：
`u_fifo/rd_gray_w1[10:0]`、`u_fifo/wr_gray_r1[10:0]`、
`start_meta`、`ctrl_fault_meta`、`pixel_fault_meta`。
所有第二同步级仍应正常STA，复位另按域同步释放。

验证入口：`bash sim/stream_label/run.sh`。黄金直接从只读原BMP24按RGB565位截断解码，
不使用区段ROM生成期望值；模型按物理底行优先模拟BL8读取。
覆盖完整两帧扫描/区段内部零/逐像素label-image同拍、首帧预填/背压、异步相位、
交替同拍/次拍done、可变burst延迟、途中复位、错beat地址、提前done、内存断供。
结果以 `sim/stream_label/logs/` 实际日志为准；尚无本模块独立TD实测。

2026-10-04实际结果：Verilator5.032 `-Wall` lint 0错误0告警；
正常两帧614400词、途中复位后一帧307200词，共921600词逐位0失配；
错beat地址33、提前done34、内存断供31全部锁存并通过。
临时副本 `{label,image}` 交换变异由同一BMP黄金在首帧x207/y0杀死，
期望bdb90000/实际0000bdb9；生产源码未变。
`logs/input.sha256`记录真实编译输入，`logs/source_check.log`复核全部6项一致。
`node sim/stream_label/check_rom.cjs`核验生成case的480项与冻结ROM逐项一致。
这些为行链RTL/内存模型证据，不能替代真实SDRAM/TF集成台、物理TD或上板。
