`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// task_052 双板以太网 PCM 探针核心(主从共用, 差别只有 ROLE 参数)。
//
// 时钟域划分(六维审查"时钟"项, 三个域):
//   app_clk  (25MHz, 本板 tx PLL 的 C3 输出): 全部"应用"逻辑 —— 发包机、收包机、
//            记录 FIFO、统计、LED/dled、epoch、离线计时。它是 clk_50 的同源衍生
//            前向时钟, 与链路有没有建立无关, 所以没链路时发送端照样跑(不会死锁)。
//            搬过来的原因: 实测 125MHz 下 byte_idx -> 字节译码(索引算术 + 图形
//            混合 + mux) -> CRC 是 8~9 级逻辑, rx_clk 域 WNS -2.939ns、tx_clk_125
//            域 WNS -1.488ns, 而业务平均只有约 112 字节/ms, 用 40ns 一拍绰绰有余。
//   tx_clk   (125MHz): TEMAC 发送半、RGMII ODDR、以及新增的 TX 排空机。
//   rx_clk_use(125MHz, RX_PHASE 选 0°/90°): TEMAC 接收半、RGMII IDDR、新增的 RX 捕获机。
//   clk_50   : 只承担上电保持计数, 不进数据通路。
//   跨域只有两个结构: 字节 FIFO(10bit x 512, 灰码指针) 与单 bit 2FF(rx_locked、
//   rxc 翻转沿、按键、拨码)。app<->tx 同源不豁免, 由 STA 真实分析; app<->rx 异步豁免。
//
// 复位: 三域各自"异步断言 + 本域同步释放"(LESSON-014)。接收域释放条件含
// rx_locked, 因此 RXC 缺失时接收侧被异步压在复位态, RXC 一出现再走 2 拍同步释放。
// 发送域与应用域都不等链路建立 —— 否则"没链路就不发 -> 永远建不起链路"死锁。
// app_rst 里带 tx_locked 是为了把"PLL 还没稳"期间的字节 FIFO 两侧指针一起清零:
// 异步 FIFO 只有一侧指针被复位会让占用差跑飞, 从而长时间认为"装不下一帧"而停发。
//------------------------------------------------------------------------------
module ethm_link_core #(
    parameter [47:0] SRC_MAC     = 48'h02_00_00_52_4D_01,
    parameter [47:0] DST_MAC     = 48'h02_00_00_52_53_02,
    parameter [7:0]  PKT_TYPE    = 8'd1,
    parameter [16:0] PACE_NORMAL = 17'd48000,
    parameter [16:0] PACE_BOOST  = 17'd60000,
    parameter [31:0] DELIV_REV   = 32'h0520_0001,
    parameter        LED_LOW     = 0,
    parameter [7:0]  RX_PHASE    = 8'd0
)(
    input  wire        clk_50,

    input  wire        phy_rxc,
    input  wire        phy_rx_ctl,
    input  wire [3:0]  phy_rxd,
    output wire        phy_txc,
    output wire        phy_tx_ctl,
    output wire [3:0]  phy_txd,

    input  wire        key_reset,
    input  wire        key_clear,
    input  wire        key_restart,
    input  wire [3:0]  sw,

    output wire [3:0]  led,
    output wire [15:0] dled
);
    localparam [17:0] DB_MAX = 18'd50_000;    // 2ms @25MHz(按键/拨码现在在 app 域)

    // ---------------- 线网 ----------------
    wire tx_clk;
    wire tx_clk90;
    wire app_clk;
    wire tx_locked;
    wire rx_clk0;
    wire rx_clk90;
    wire rx_clk_use;
    wire rx_locked;
    wire tx_rst;
    wire rx_rst;
    wire app_rst;
    reg  ms_tick;
    wire rec_rd_en;
    wire boost_en;
    wire [2:0] page_sel;
    wire clear_p;
    wire restart_p;
    wire [31:0] epoch;

    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire        gmii_tx_er;
    wire [7:0]  gmii_rxd;
    wire        gmii_rx_dv;
    wire        gmii_rx_er;
    wire        gmii_crs;
    wire        gmii_col;
    wire [7:0]  app_rx_data;
    wire        app_rx_data_vld;
    wire        app_rx_correct_frame;
    wire        app_rx_error_frame;
    wire [7:0]  app_tx_data;
    wire        app_tx_data_en;
    wire        app_tx_rdy;
    wire        app_tx_retransmit;
    wire        app_tx_collision;
    wire        speed_1000;
    wire [3:0]  rxc_rate_code;
    wire [15:0] dled_raw;
    wire [3:0]  led_raw;
    wire        rx_mac_fault;

    // ---------------- 上电保持(让 PLL 先稳定) ----------------
    reg [19:0] boot_hold;
    reg        boot_done_r;
    wire       boot_done = boot_done_r;      // 源域寄存后的准静态门控
    always @(posedge clk_50) begin
        // v6c: 译码结果先在本域寄存, 再送各域两级同步器 => 跨域那条路径中间没有 LUT。
        // 单调冻结: 一旦 boot_done_r 起来就不再计数也不回落(上电门控只走一次)。
        if (!boot_done_r) begin
            boot_hold   <= boot_hold + 20'd1;
            boot_done_r <= (boot_hold >= 20'd500_000);
        end
    end

    // 上电保持的"释放"条件必须在各域自己同步后再用: clk_50 计数器的末位直接
    // 送到 125MHz/25MHz 域会拉出一条真实的跨域组合路径(以前是走异步断言那条
    // 不受 STA 保护的路), 现在每个域各取两拍, 与各自的复位同步器同域。
    // 接收域**不需要** boot_done 门: 它的异步断言是 !rx_locked, RXC 没来之前整个
    // 域没有时钟, 一拍时钟出现后 rx_rsync 自己走两拍再释放 —— 已经是本域对齐的释放。
    // 曾加过一级 bh_rx 同步器, 结果凭空造出 clk_50 -> rx_clk_0 这条异步跨域路径
    // (TD 按 20ns/8ns 的任意相对相位只给 4ns 预算, 违例 -1.034ns), 删掉即无违例,
    // 也不用为了它去加 false path。
    reg [1:0] bh_tx;
    reg [1:0] bh_app;
    always @(posedge tx_clk)  bh_tx  <= {bh_tx[0],  boot_done};
    always @(posedge app_clk) bh_app <= {bh_app[0], boot_done};
    wire boot_ok_tx   = bh_tx[1];
    wire boot_ok_app  = bh_app[1];

    // ---------------- 三域复位 ----------------
    // 异步断言源只允许是"引脚/PLL lock 脚"这类真异步信号; boot_done 属 clk_50 域
    // 寄存器, 以前直接进复位表达式, TD 会把它挂到发送/应用域触发器的 sr 脚上做
    // removal 检查 => clk_50 -> tx_clk_125 违例 -1.747ns。现在改成: 先 2FF 同步进
    // 本域, 再作为"释放门"串在同步释放之后 => 断言仍是异步的, 释放仍是本域对齐的。
    wire tx_rst_req  = (!key_reset) || (!tx_locked);
    wire rx_rst_req  = (!key_reset) || (!rx_locked);
    wire app_rst_req = (!key_reset) || (!tx_locked);

    reg [1:0] tx_rsync;
    always @(posedge tx_clk or posedge tx_rst_req) begin
        if (tx_rst_req) tx_rsync <= 2'b00;
        else            tx_rsync <= {tx_rsync[0], 1'b1};
    end
    // 释放门: PLL 锁 + 上电保持(已同步到本域)都满足后才真正释放
    assign tx_rst = ~tx_rsync[1] || !boot_ok_tx;

    reg [1:0] rx_rsync;
    always @(posedge rx_clk_use or posedge rx_rst_req) begin
        if (rx_rst_req) rx_rsync <= 2'b00;
        else            rx_rsync <= {rx_rsync[0], 1'b1};
    end
    assign rx_rst = ~rx_rsync[1];

    reg [1:0] app_rsync;
    always @(posedge app_clk or posedge app_rst_req) begin
        if (app_rst_req) app_rsync <= 2'b00;
        else             app_rsync <= {app_rsync[0], 1'b1};
    end
    assign app_rst = ~app_rsync[1] || !boot_ok_app;


    // ---------------- 按键同步 + 去抖 + 上升沿脉冲(app 域) ----------------
    reg [1:0] clr_sync;
    reg [1:0] rst_sync;
    reg       clr_stable;
    reg       rst_stable;
    reg [17:0] clr_cnt;
    reg [17:0] rst_cnt;
    reg        clear_p_r;
    reg        restart_p_r;
    reg        clr_stable_d;
    reg        rst_stable_d;

    always @(posedge app_clk) begin
        clr_sync <= {clr_sync[0], key_clear};
        rst_sync <= {rst_sync[0], key_restart};
    end
    assign clear_p   = clear_p_r;
    assign restart_p = restart_p_r;

    always @(posedge app_clk) begin
        if (app_rst) begin
            clr_stable  <= 1'b0;
            rst_stable  <= 1'b0;
            clr_cnt     <= 18'd0;
            rst_cnt     <= 18'd0;
            clear_p_r   <= 1'b0;
            restart_p_r <= 1'b0;
            clr_stable_d<= 1'b0;
            rst_stable_d<= 1'b0;
        end
        else begin
            clear_p_r   <= 1'b0;
            restart_p_r <= 1'b0;

            if (clr_sync[1] == clr_stable)
                clr_cnt <= 18'd0;
            else if (clr_cnt == DB_MAX) begin
                clr_cnt    <= 18'd0;
                clr_stable <= clr_sync[1];
            end
            else
                clr_cnt <= clr_cnt + 18'd1;

            if (rst_sync[1] == rst_stable)
                rst_cnt <= 18'd0;
            else if (rst_cnt == DB_MAX) begin
                rst_cnt    <= 18'd0;
                rst_stable <= rst_sync[1];
            end
            else
                rst_cnt <= rst_cnt + 18'd1;

            clr_stable_d <= clr_stable;
            rst_stable_d <= rst_stable;
            if (clr_stable && !clr_stable_d)  clear_p_r   <= 1'b1;
            if (rst_stable && !rst_stable_d)  restart_p_r <= 1'b1;
        end
    end

    // ---------------- 拨码(静态, 2FF, app 域) ----------------
    reg [3:0] sw_s1;
    reg [3:0] sw_s2;
    always @(posedge app_clk) begin
        if (app_rst) begin
            sw_s1 <= 4'd0;
            sw_s2 <= 4'd0;
        end
        else begin
            sw_s1 <= sw;
            sw_s2 <= sw_s1;
        end
    end
    assign boost_en = sw_s2[0];
    assign page_sel = sw_s2[3:1];

    // ---------------- 毫秒节拍(全设计唯一时间基准, 25MHz) ----------------
    reg [26:0] ms_acc;
    always @(posedge app_clk) begin
        if (app_rst) begin
            ms_acc  <= 27'd0;
            ms_tick <= 1'b0;
        end
        else if (ms_acc == 27'd24_999) begin
            ms_acc  <= 27'd0;
            ms_tick <= 1'b1;
        end
        else begin
            ms_acc  <= ms_acc + 27'd1;
            ms_tick <= 1'b0;
        end
    end

    // ---------------- 时钟 ----------------
    ethm_pll_tx u_pll_tx (
        .clk_50    (clk_50),
        .pll_rst   (!boot_done),
        .tx_clk    (tx_clk),
        .tx_clk90  (tx_clk90),
        .app_clk   (app_clk),
        .tx_locked (tx_locked)
    );

    ethm_pll_rx u_pll_rx (
        .rx_clk_pin (phy_rxc),
        .pll_rst    (!boot_done),
        .rx_clk0    (rx_clk0),
        .rx_clk90   (rx_clk90),
        .rx_locked  (rx_locked)
    );

    // 官方两份例程对采样相位结论相反(90° vs 0°), 差别在于板级是否已按 Realtek
    // 要求给 RXC 多绕 1.5~2.0ns 走线延迟。本包把相位做成参数: 两颗 bit 只差这一
    // 个取值, 上板一次即可判定, 不靠猜。
    assign rx_clk_use = (RX_PHASE == 8'd90) ? rx_clk90 : rx_clk0;

    // ---------------- TEMAC + RGMII ----------------
    wire [47:0] local_mac_rev = {SRC_MAC[7:0],  SRC_MAC[15:8], SRC_MAC[23:16],
                                 SRC_MAC[31:24], SRC_MAC[39:32], SRC_MAC[47:40]};

    ethm_temac u_temac (
        .reset                (tx_rst),
        .tx_mac_clk           (tx_clk),
        .rx_mac_clk           (rx_clk_use),
        .app_tx_data          (app_tx_data),
        .app_tx_data_en       (app_tx_data_en),
        .app_tx_rdy           (app_tx_rdy),
        .app_tx_retransmit    (app_tx_retransmit),
        .app_tx_collision     (app_tx_collision),
        .app_rx_data          (app_rx_data),
        .app_rx_data_vld      (app_rx_data_vld),
        .app_rx_correct_frame (app_rx_correct_frame),
        .app_rx_error_frame   (app_rx_error_frame),
        .gmii_txd             (gmii_txd),
        .gmii_tx_en           (gmii_tx_en),
        .gmii_tx_er           (gmii_tx_er),
        .gmii_rxd             (gmii_rxd),
        .gmii_rx_dv           (gmii_rx_dv),
        .gmii_rx_er           (gmii_rx_er),
        .gmii_crs             (gmii_crs),
        .gmii_col             (gmii_col),
        .local_mac_rev        (local_mac_rev),
        .speed_1000           (speed_1000)
    );

    ethm_rgmii_tx u_rgmii_tx (
        .tx_clk       (tx_clk),
        .tx_clk90     (tx_clk90),
        .tx_rst       (tx_rst),
        .gmii_txd     (gmii_txd),
        .gmii_tx_en   (gmii_tx_en),
        .gmii_tx_er   (gmii_tx_er),
        .rgmii_txd    (phy_txd),
        .rgmii_tx_ctl (phy_tx_ctl),
        .rgmii_txc    (phy_txc)
    );

    ethm_rgmii_rx u_rgmii_rx (
        .rx_clk       (rx_clk_use),
        .rgmii_rxd    (phy_rxd),
        .rgmii_rx_ctl (phy_rx_ctl),
        .gmii_tx_en   (gmii_tx_en),
        .gmii_tx_er   (gmii_tx_er),
        .gmii_rxd     (gmii_rxd),
        .gmii_rx_dv   (gmii_rx_dv),
        .gmii_rx_er   (gmii_rx_er),
        .gmii_crs     (gmii_crs),
        .gmii_col     (gmii_col)
    );

    assign rx_mac_fault = app_tx_retransmit | app_tx_collision;

    // ---------------- 发送: app 域发包机 -> 字节 FIFO -> tx 域排空机 ----------------
    wire tx_frame_done;
    wire tx_pacer_overrun;
    wire [15:0] tx_stall_max;
    wire [31:0] tx_frames;

    wire        txf_wr_en;
    wire [9:0]  txf_wr_data;
    wire        txf_wr_full;
    wire        txf_wr_space;
    wire        txf_wr_ovf;        // 见 ethm_tx_pack 头部: 起帧已预留整帧空间,
                                   // 这一路满只可能是结构性 bug, 故意不并入业务
                                   // 计数(混进 c_rx_drop 会污染"溢出为 0"判据)
    wire [9:0]  txf_rd_data;
    wire [1:0]  txf_rd_kind;
    wire        txf_rd_vld;
    wire        txf_rd_last;
    wire        txf_rd_empty;
    wire        txf_rd_en;
    wire [9:0]  txf_rd_usedw;      // 给排空机判"整帧是否已经装齐"(见 ethm_tx_drain)
    // 帧内断供(该帧已损坏)的单拍脉冲。本包计数器集合与 dled 页是冻结的, 不再新增
    // 计数项, 所以这一路保留成可探信号(ChipWatcher)而不是悄悄让它被综合剪掉。
    wire        tx_underrun;  //synthesis keep

    ethm_tx_pack u_tx_pack (
        .clk              (app_clk),
        .rst              (app_rst),
        .pace_step        (boost_en ? PACE_BOOST : PACE_NORMAL),
        .pkt_type         (PKT_TYPE),
        .pkt_flags        ({15'd0, boost_en}),
        .epoch            (epoch),
        .dst_mac          (DST_MAC),
        .src_mac          (SRC_MAC),
        .fifo_wr_en       (txf_wr_en),
        .fifo_wr_data     (txf_wr_data),
        .fifo_wr_space    (txf_wr_space),
        .fifo_wr_full     (txf_wr_full),
        .frame_done       (tx_frame_done),
        .tx_frames        (tx_frames),
        .tx_pacer_overrun (tx_pacer_overrun),
        .tx_stall_max     (tx_stall_max),
        .tx_seq_now       ()
    );

    // SPACE_MIN=320 > 306: 起帧那一拍就一次性预留整帧空间(见 ethm_bafifo 头部)
    ethm_bafifo #(.SPACE_MIN(320)) u_txfifo (
        .wr_clk    (app_clk),
        .wr_rst    (app_rst),
        .wr_en     (txf_wr_en),
        .wr_data   (txf_wr_data),
        .wr_full   (txf_wr_full),
        .wr_space  (txf_wr_space),
        .wr_ovf    (txf_wr_ovf),
        .rd_clk    (tx_clk),
        .rd_rst    (tx_rst),
        .rd_en     (txf_rd_en),
        .rd_data   (txf_rd_data),
        .rd_vld    (txf_rd_vld),
        .rd_kind   (txf_rd_kind),
        .rd_last   (txf_rd_last),
        .rd_empty  (txf_rd_empty),
        .rd_usedw  (txf_rd_usedw)
    );

    ethm_tx_drain u_tx_drain (
        .clk           (tx_clk),
        .rst           (tx_rst),
        .fifo_rd_data  (txf_rd_data),
        .fifo_rd_kind  (txf_rd_kind),
        .fifo_rd_vld   (txf_rd_vld),
        .fifo_rd_last  (txf_rd_last),
        .fifo_rd_empty (txf_rd_empty),
        .fifo_rd_usedw (txf_rd_usedw),
        .fifo_rd_en    (txf_rd_en),
        .app_tx_rdy    (app_tx_rdy),
        .tx_data       (app_tx_data),
        .tx_data_en    (app_tx_data_en),
        .underrun      (tx_underrun)
    );

    // ---------------- 接收: rx 域捕获机 -> 字节 FIFO -> app 域收包机 ----------------
    wire        rxf_wr_en;
    wire [9:0]  rxf_wr_data;
    wire        rxf_wr_full;
    wire        rxf_wr_ovf;        // 与 rx_capture 自己的 fifo_overflow 同口径
    wire [9:0]  rxf_rd_data;
    wire [1:0]  rxf_rd_kind;
    wire        rxf_rd_vld;
    wire        rxf_rd_last;
    wire        rxf_rd_empty;
    wire        rxf_rd_en;
    wire [9:0]  rxf_rd_usedw;      // RX 字节 FIFO 占用 -> 统计域 max 水位(积压真值)
    // 快域单拍溢出脉冲: 25MHz 域直接采样一定会漏, 所以统计走"按帧上报"的那一路
    // (元数据 truncated 位 -> rx_pack 的 of_evt)。本信号留作可探观测点。
    wire        cap_overflow; //synthesis keep

    // ================= 离线冲刷序列(LINK_REPORT 6.1.1 R-b) =================
    // 冲刷不新增任何异步清零路径, 也不给 FIFO 加端口: 它就是在**本域**复位输入上或一个
    // 本域产生的电平。app_flush 打读侧(rxfifo 读侧 + 收包机 + 记录 FIFO),
    // rx_flush 打写侧(rxfifo 写侧 + rx_capture), 后者由 2FF 同步得到。
    // 次序是硬要求: 断言时读侧当拍归零、写侧两拍后才归零; 释放时读侧先放开、写侧晚两拍。
    // 反过来的话写侧先归零而读侧 rd_bin 还是旧值, usedw = wr - rd 会回绕成一个巨大的
    // 假占用, rd_empty 判不成立, 读侧就把根本不存在的字节当数据吃掉(假帧 + 假 CRC 错)。
    reg       flush_lvl;
    reg [4:0] flush_cnt;
    reg [9:0] flush_drop_hold;
    wire      offline_evt;
    wire      fft_ready_w;      //synthesis keep
    wire      flush_start = offline_evt;
    wire      flush_done  = flush_lvl && (flush_cnt == 5'd16);

    always @(posedge app_clk) begin
        if (app_rst) begin
            flush_lvl       <= 1'b0;
            flush_cnt       <= 5'd0;
            flush_drop_hold <= 10'd0;
        end
        else begin
            if (!flush_lvl && flush_start) begin
                flush_lvl       <= 1'b1;
                flush_cnt       <= 5'd0;
                flush_drop_hold <= rxf_rd_usedw;   // 本次丢弃量: 本域快照, 不跨域计数
            end
            else if (flush_lvl) begin
                if (flush_cnt < 5'd16) flush_cnt <= flush_cnt + 5'd1;
                else                   flush_lvl <= 1'b0;
            end
        end
    end

    reg [1:0] fl_rx_s;
    always @(posedge rx_clk_use) fl_rx_s <= {fl_rx_s[0], flush_lvl};
    wire app_flush = flush_lvl;
    wire rx_flush  = fl_rx_s[1];

    ethm_rx_capture u_rx_capture (
        .clk             (rx_clk_use),
        .rst             (rx_rst | rx_flush),
        .rx_data         (app_rx_data),
        .rx_data_vld     (app_rx_data_vld),
        .rx_correct_frame(app_rx_correct_frame),
        .rx_error_frame  (app_rx_error_frame),
        .fifo_wr_full    (rxf_wr_full),
        .fifo_wr_en      (rxf_wr_en),
        .fifo_wr_data    (rxf_wr_data),
        .fifo_overflow   (cap_overflow)
    );

    ethm_bafifo u_rxfifo (
        .wr_clk    (rx_clk_use),
        .wr_rst    (rx_rst | rx_flush),
        .wr_en     (rxf_wr_en),
        .wr_data   (rxf_wr_data),
        .wr_full   (rxf_wr_full),
        .wr_space  (),
        .wr_ovf    (rxf_wr_ovf),
        .rd_clk    (app_clk),
        .rd_rst    (app_rst | app_flush),
        .rd_en     (rxf_rd_en),
        .rd_data   (rxf_rd_data),
        .rd_vld    (rxf_rd_vld),
        .rd_kind   (rxf_rd_kind),
        .rd_last   (rxf_rd_last),
        .rd_empty  (rxf_rd_empty),
        .rd_usedw  (rxf_rd_usedw)
    );

    wire        push_req;
    wire [31:0] push_word;
    wire        push_dropped;
    wire        busy_dropped;
    wire        of_evt;
    wire        fifo_full;
    wire        fifo_space_ok;
    wire [31:0] fifo_rd_data;
    wire        fifo_rd_empty;
    wire [6:0]  fifo_rd_used;
    wire        rec_wr_en;
    wire        rec_of;

    ethm_rx_pack u_rx_pack (
        .clk             (app_clk),
        .rst             (app_rst | app_flush),
        .fifo_rd_data    (rxf_rd_data),
        .fifo_rd_kind    (rxf_rd_kind),
        .fifo_rd_vld     (rxf_rd_vld),
        .fifo_rd_last    (rxf_rd_last),
        .fifo_rd_empty   (rxf_rd_empty),
        .fifo_rd_en      (rxf_rd_en),
        .expect_da       (SRC_MAC),
        .push_ready      (fifo_space_ok),
        .push_req        (push_req),
        .push_word       (push_word),
        .push_dropped    (push_dropped),
        .busy_dropped    (busy_dropped),
        .of_evt          (of_evt)
    );

    // 记录交接: 收包机与统计现在同在 app_clk, 这根 FIFO 退化成本域同步 FIFO
    // (两侧时钟同频同源, 灰码同步链只剩"晚两拍"的保守裕量, 不再有亚稳风险)。
    // 仍然按"整条记录装得下才写、装不下就计数丢弃"办, 契约要求溢出必须可见。
    assign rec_wr_en = push_req && !fifo_full;
    assign rec_of    = push_req &&  fifo_full;

    ethm_rec_fifo u_rec_fifo (
        .wr_clk      (app_clk),
        .wr_rst      (app_rst | app_flush),
        .wr_en       (rec_wr_en),
        .wr_data     (push_word),
        .wr_full     (fifo_full),
        .wr_space_ok (fifo_space_ok),
        .rd_clk      (app_clk),
        .rd_rst      (app_rst | app_flush),
        .rd_en       (rec_rd_en),
        .rd_data     (fifo_rd_data),
        .rd_empty    (fifo_rd_empty),
        .rd_usedw    (fifo_rd_used)
    );

    // ---------------- RXC 速率 / 链路存在性 ----------------
    reg [2:0] rx_lock_s;
    always @(posedge app_clk) begin
        if (app_rst) rx_lock_s <= 3'd0;
        else         rx_lock_s <= {rx_lock_s[1:0], rx_locked};
    end

    // 分频翻转仍在 rx_clk_use(它量的就是 RXC 本身), 窗口计数搬到 app_clk:
    // 8ms 窗口由 25MHz 的 ms_tick 给出, 每 4096 拍一次的沿数还是约 244 个/8ms,
    // 分档阈值不用改(见 ethm_rxc_rate)。
    ethm_rxc_rate u_rxc_rate (
        .rx_clk     (rx_clk_use),
        .clk        (app_clk),
        .rx_rst     (rx_rst),
        .tx_rst     (app_rst),
        .ms_tick    (ms_tick),
        .rate_code  (rxc_rate_code)
    );

    // ---------------- 统计 / 观测(app_clk) ----------------
    ethm_stats #(
        .DELIV_REV   (DELIV_REV),
        .EXPECT_TYPE (PKT_TYPE)
    ) u_stats (
        .clk              (app_clk),
        .rst              (app_rst),
        .ms_tick          (ms_tick),
        .flush_done       (flush_done),
        .flush_drop_n     (flush_drop_hold),
        .offline_evt      (offline_evt),
        .fft_ready        (fft_ready_w),
        .rec_data         (fifo_rd_data),
        .rec_empty        (fifo_rd_empty),
        .rec_usedw        (fifo_rd_used),
        .rxf_usedw        (rxf_rd_usedw),
        .rec_rd_en        (rec_rd_en),
        .rec_drop_evt     (push_dropped),
        .busy_drop_evt    (busy_dropped),
        .rec_of_evt       (rec_of),
        .cap_of_evt       (of_evt),
        .tx_pacer_overrun (tx_pacer_overrun),
        .tx_stall_max     (tx_stall_max),
        .tx_frames        (tx_frames),
        .tx_mac_fault     (rx_mac_fault),
        .rx_locked        (rx_lock_s[2]),
        .speed_1000       (speed_1000),
        .rxc_rate_code    (rxc_rate_code),
        .force_restart    (restart_p),
        .clear_sticky     (clear_p),
        .page_sel         (page_sel),
        .epoch            (epoch),
        .dled_val         (dled_raw),
        .led              (led_raw)
    );

    assign led  = (LED_LOW == 0) ? led_raw  : ~led_raw;
    assign dled = (LED_LOW == 0) ? dled_raw : ~dled_raw;
endmodule
