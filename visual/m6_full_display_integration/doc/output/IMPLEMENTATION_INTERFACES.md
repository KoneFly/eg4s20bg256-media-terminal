# M6-FDI 实施接口与当前授权

2026-10-04 用户已明确确认按裁剪方案实施；一页评审确认点已通过。总资源90%门禁不变，超限即停待裁。所有编辑仅在本任务副本 project/ 中；上游和 reference/base_src 只读。既有正式W2/S2端口不改。

新增模块接口如下，便于并行实现；改动需相互通知。

```verilog
module fdi_label_store (
 input wire clk, mem_clk, rst_n,
 input wire sd_miso,
 output wire sd_dclk, sd_mosi, sd_ncs,
 output wire label_ready,
 output wire [7:0] error_code,
 input wire rd_req_valid,
 input wire [20:0] rd_req_addr,
 output wire rd_req_ready,
 output wire rd_beat_valid,
 output wire [31:0] rd_beat_data,
 output wire [20:0] rd_beat_addr,
 output wire rd_done
);
module fdi_label_stream (
 input wire clk, rst_n, label_ready,
 output wire rd_req_valid,
 output wire [20:0] rd_req_addr,
 input wire rd_req_ready, rd_beat_valid,
 input wire [31:0] rd_beat_data,
 input wire [20:0] rd_beat_addr,
 input wire rd_done,
 input wire pixel_clk, pixel_rst, pixel_take,
 output wire [31:0] pixel_data,
 output wire pixel_valid, pixel_ready,
 output wire [7:0] error_code
);
```

存储端以BL8对齐字址接受请求，busy期间不接受下一请求；每burst固定8个rd_beat，rd_done标记事务完成。启动阶段内部加载/全量校验独占存储，label_ready=1后读服务开放，刷新优先，不再写。物理数据底行优先，文件CRC47E2A01D，物理标签CRC A1E4D4E1。错误锁存，label_ready失败时为0。

行链按照逻辑y0..479/x0..639连续循环生产FIFO；y>=451和区段外补0，FIFO词{label,16'd0}。行缓存单项，先填BL8区段再生产该行，完成后才复用；AFULL_MARGIN=36与1024×32保持。pixel_take在像素域发读请求，pixel_valid为接受读请求后寄存数据可消费的拍，pixel_data同拍；pixel_ready是首帧预填达到安全水位且同步到像素域的电平，必须独立于pixel_take生成，防启动依赖。出现空读须锁存错误，不假冒正常0标签。

v9_m6_scan副本增加像素域pixel_ready/data/valid及pixel_take接口、label_ready输入与ctrl_clk/ctrl_rst_n；根负责hdmi/top封装。内部W2在ctrl50域，v9_spectrum_snapshot仍在原clk/pixel域保持源码不变；在label_ready后才开始首次W2更新，所有更新在消隐515开始，收集稳定1024bit向量并握手到W2。初始commit接收与ack独立于S2输入/label FIFO开放，state_committed及pixel_ready共同在完整帧边界使能扫描，保持初始生长在标签加载后发生。

W2写口并联pcb_state_mem和S2 barcache；状态表自由运行同步1拍读，不修改W2652写顺序/commit/done/ack语义。S2输入valid为与FIFO寄存输出对齐的de，不因显示流水延迟改变HDMI参数；沿用双行缓存重定时。新增故障码供根汇合到已有LED/数码管，不改通信应用层。

根负责PLL副本C1/C3双50时钟、ADC/SDC、顶层接线、预算TD、工程diff与证据。下游模块各有独立作者负责的文件，禁止并发改同文件。
