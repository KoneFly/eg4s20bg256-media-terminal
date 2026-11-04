`timescale 1ns / 1ps
// ============================================================================
// display_dma — 线性整帧扫描读 DMA(ctrl 域), 每帧先写一个描述字
//
// 每收到一次像素域帧尾通知(frame_tog 翻转, 有效区结束、VBlank 开始), 发
// scan_req; 下一拍起 scan_ack 给出本次扫描的 {页基址, 是否扫描, 描述 desc}。
// 帧开始时先向异步 FIFO 写一个描述字 {1, desc}(位 32 = 帧首标记), 随后以 QW
// 字量子顺序读出 PAGE_WORDS 个像素字({0, P1P0})。像素端以描述字对齐帧首并
// 取得本帧参数(层使能/转场模式/进度), 参数因此与像素严格同帧。
// 发起条件: FIFO 可见占用 + 在途字 + 本次字数 <= DEPTH, 读突发不被背压。
// 新帧首个请求要等上一帧在途读全部返回, 描述字之后的首字必为本帧首字。
// 新帧通知到达时上一帧仍未发完(欠服务) => 剩余请求放弃, late_cnt 计数。
// scan_valid=0 时本帧不扫描(该层输出黑/不参与)。
// 按行读: 每行 320 字分两次 QW=160 字请求; 描述字 [13:12] 为缩放级别 b,
//   第 r 行读源行 (r>>b)<<b(垂直块状重复), 水平保持在像素端完成。
// ============================================================================
module display_dma #(
    parameter [20:0] PAGE_WORDS    = 21'd153600,
    parameter integer FIFO_DEPTH   = 1024,
    parameter integer URGENT_WORDS = 384,
    parameter integer QW           = 160    // 每次读请求字数 = 半行
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_tog,       // 像素域翻转信号(未同步)

    output reg         scan_req,
    input  wire        scan_ack,
    input  wire [20:0] scan_base,
    input  wire        scan_valid,
    input  wire [31:0] scan_desc,

    output wire        r_valid,
    output wire        r_urgent,
    output wire [20:0] r_addr,
    output wire [8:0]  r_len,
    input  wire        r_grant,

    input  wire        rd_valid,
    input  wire [31:0] rd_data,

    output wire        fifo_wr_en,
    output wire [32:0] fifo_wr_data,
    input  wire [$clog2(FIFO_DEPTH):0] fifo_level,

    output reg  [15:0] late_cnt
);
    localparam integer LW = $clog2(FIFO_DEPTH) + 1;

    reg [2:0] tog_s;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) tog_s <= 3'b000; else tog_s <= {tog_s[1:0], frame_tog};
    wire frame_evt = tog_s[2] ^ tog_s[1];

    reg        active;          // 本帧仍有未发出的请求
    reg [20:0] base, acc, zrow;      // acc = 行号*320, zrow = 当前源行偏移
    reg [8:0]  rrow;
    reg        rh;
    reg [LW:0] inflight;
    reg        start_wait;      // 已拿到新基址, 等在途读排空后写描述字
    reg [31:0] desc;

    wire [LW+1:0] need = fifo_level + inflight + QW;
    assign r_valid  = active && (need <= FIFO_DEPTH);
    assign r_urgent = (fifo_level + inflight) < URGENT_WORDS;
    assign r_addr   = base + zrow + (rh ? 21'd160 : 21'd0);
    wire [1:0]  zb      = desc[13:12];
    wire [8:0]  zmask   = (zb == 2'd1) ? 9'd1 : (zb == 2'd2) ? 9'd3 : 9'd0;
    wire [8:0]  rrow_n  = rrow + 9'd1;
    assign r_len    = QW;

    // 描述字写入拍: 无在途读、无读数据返回、FIFO 有空位
    wire hdr_wr = start_wait && (inflight == 0) && !rd_valid && (fifo_level < FIFO_DEPTH - 1);

    assign fifo_wr_en   = rd_valid || hdr_wr;
    assign fifo_wr_data = hdr_wr ? {1'b1, desc} : {1'b0, rd_data};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active     <= 1'b0;
            base       <= 21'd0;
            acc        <= 21'd0;
            zrow       <= 21'd0;
            rrow       <= 9'd0;
            rh         <= 1'b0;
            inflight   <= {(LW+1){1'b0}};
            start_wait <= 1'b0;
            desc       <= 32'd0;
            scan_req   <= 1'b0;
            late_cnt   <= 16'd0;
        end else begin
            scan_req <= 1'b0;
            case ({r_grant, rd_valid})
            2'b10: inflight <= inflight + QW;
            2'b11: inflight <= inflight + (QW - 1);
            2'b01: inflight <= inflight - 1'b1;
            default: ;
            endcase

            if (frame_evt) begin
                if (active && late_cnt != 16'hFFFF) late_cnt <= late_cnt + 16'd1;
                active     <= 1'b0;
                start_wait <= 1'b0;
                scan_req   <= 1'b1;
            end else if (scan_ack) begin
                base       <= scan_base;
                acc        <= 21'd0;
                zrow       <= 21'd0;
                rrow       <= 9'd0;
                rh         <= 1'b0;
                desc       <= scan_desc;
                start_wait <= scan_valid;
            end else if (hdr_wr) begin
                start_wait <= 1'b0;
                active     <= 1'b1;
            end else if (r_grant) begin
                rh <= !rh;
                if (rh) begin
                    rrow <= rrow_n;
                    acc  <= acc + 21'd320;
                    if ((rrow_n & zmask) == 9'd0) zrow <= acc + 21'd320;
                    if (rrow == 9'd479) active <= 1'b0;
                end
            end
        end
    end
endmodule
