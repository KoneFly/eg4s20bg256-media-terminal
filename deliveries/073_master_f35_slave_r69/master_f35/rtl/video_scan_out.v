`timescale 1ns / 1ps
// video_scan_out：640×480像素扫描和双层FIFO解包。模式0直通、1淡入淡出、3擦除、4幕布；描述字同时携带采样档位与图墙焦点，输出时序随合成流水延迟对齐。
module video_scan_out (
    input  wire        clk,             // 25.2MHz
    input  wire        rst,             // 高有效
    output reg         frame_tog,

    output wire        a_rd_en,
    input  wire [32:0] a_rd_data,
    input  wire        a_empty,
    output wire        b_rd_en,
    input  wire [32:0] b_rd_data,
    input  wire        b_empty,

    output reg         o_hs,
    output reg         o_vs,
    output reg         o_de,
    output reg  [15:0] o_rgb565,
    output reg         o_sof,           // 每帧首有效像素(A 层已锁定)
    output reg  [9:0]  o_x, o_y,       // 与o_rgb565/o_de严格同拍的有效区坐标
    output reg         o_frame_boundary,

    output reg  [15:0] underflow_cnt,   // 有效区内缺字的帧数(两层合计)
    output reg  [15:0] seek_drop_cnt    // SEEK 丢弃字数(两层合计)
);
    localparam integer HTOTAL = 800, HSA = 96, HSTART = 144, HEND = 784;
    localparam integer VTOTAL = 525, VSA = 2,  VSTART = 35,  VEND = 515;

    reg [9:0] hc, vc;
    always @(posedge clk or posedge rst) begin
        if (rst) begin hc <= 10'd0; vc <= 10'd0; end
        else if (hc == HTOTAL - 1) begin
            hc <= 10'd0;
            vc <= (vc == VTOTAL - 1) ? 10'd0 : vc + 10'd1;
        end else hc <= hc + 10'd1;
    end

    wire de    = (hc >= HSTART) && (hc < HEND) && (vc >= VSTART) && (vc < VEND);
    wire vact  = (vc >= VSTART) && (vc < VEND);
    wire first = (hc == HSTART) && (vc == VSTART);
    wire fend  = (hc == 10'd0) && (vc == VEND);
    wire odd   = hc[0] ^ HSTART[0];
    wire [9:0] px_x = hc - HSTART;
    wire [9:0] px_y = vc - VSTART;

    // ---- 每层: 两项预取队列 + 帧锁定 ----
    wire        a_lock, b_lock, a_bad, b_bad, a_have, b_have;
    wire [32:0] a_q, b_q;
    wire        a_drop, b_drop, a_ufl, b_ufl, a_lp, b_lp;
    wire        b_use;

    scan_layer u_la (.clk(clk), .rst(rst), .fend(fend), .vact(vact),
        .need(de), .odd(odd), .use_layer(1'b1),
        .rd_en(a_rd_en), .rd_data(a_rd_data), .empty(a_empty),
        .locked(a_lock), .bad(a_bad), .have(a_have), .q(a_q), .dropped(a_drop), .underflow(a_ufl), .lock_pulse(a_lp));
    scan_layer u_lb (.clk(clk), .rst(rst), .fend(fend), .vact(vact),
        .need(de), .odd(odd), .use_layer(b_use),
        .rd_en(b_rd_en), .rd_data(b_rd_data), .empty(b_empty),
        .locked(b_lock), .bad(b_bad), .have(b_have), .q(b_q), .dropped(b_drop), .underflow(b_ufl), .lock_pulse(b_lp));

    // 帧参数: A 层描述字锁定时取得
    reg [31:0] desc;
    reg        desc_ok;
    always @(posedge clk or posedge rst)
        if (rst) begin desc <= 32'd0; desc_ok <= 1'b0; end
        else if (fend) desc_ok <= 1'b0;
        else if (a_lp) begin desc <= a_q[31:0]; desc_ok <= 1'b1; end
    assign b_use = desc_ok && desc[11];

    wire a_ok = de && a_lock && !a_bad && a_have;
    wire b_ok = de && b_lock && !b_bad && b_have && b_use;
    wire [1:0]  zb   = desc_ok ? desc[13:12] : 2'd0;
    wire        zx   = (zb == 2'd1) ? !px_x[0] : (zb == 2'd2) ? (px_x[1:0] == 2'd0) : 1'b1;
    reg  [15:0] a_hold;
    wire [15:0] a_px = !a_ok ? 16'd0 : (zb == 2'd0) ? (odd ? a_q[31:16] : a_q[15:0]) : (zx ? a_q[15:0] : a_hold);
    always @(posedge clk or posedge rst)
        if (rst) a_hold <= 16'd0; else if (de) a_hold <= a_px;
    wire [15:0] b_px = b_ok ? (odd ? b_q[31:16] : b_q[15:0]) : 16'd0;

    // ---- 合成(转场引擎): B 层不参与时强制直通 A ----
    wire        t_de;
    wire [15:0] t_px;
    transition_engine_curtain u_tr (
        .clk(clk), .rst_n(~rst),
        .a_de(de), .a_pixel(a_px), .b_de(de && b_use), .b_pixel(b_px),
        .trans_mode(b_use ? desc[2:0] : 3'd0), .trans_t(desc[10:3]),
        .px_x({2'b00, px_x}), .px_y({2'b00, px_y}),
        .out_de(t_de), .out_pixel(t_px));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            frame_tog <= 1'b0; underflow_cnt <= 16'd0; seek_drop_cnt <= 16'd0;
        end else begin
            if (fend) frame_tog <= ~frame_tog;
            if ((a_ufl || b_ufl) && underflow_cnt != 16'hFFFF) underflow_cnt <= underflow_cnt + 16'd1;
            if ((a_drop || b_drop) && seek_drop_cnt != 16'hFFFF) seek_drop_cnt <= seek_drop_cnt + 16'd1;
        end
    end

    // 时序与转场引擎输出对齐: 引擎在像素拍之后 1 拍给出结果
    reg hs1, vs1, de1, sof1, boundary1;
    reg [9:0] x1,y1;
    // 焦点框(与 x1/y1 同拍)
    wire        wall_f = desc_ok && desc[14];
    wire [9:0]  fx0 = desc[15] ? 10'd320 : 10'd0;
    wire [9:0]  fy0 = desc[16] ? 10'd240 : 10'd0;
    wire [9:0]  fdx = x1 - fx0, fdy = y1 - fy0;
    wire        f_in  = (x1 >= fx0) && (fdx < 10'd320) && (y1 >= fy0) && (fdy < 10'd240);
    wire        frame1 = wall_f && f_in && (fdx < 10'd4 || fdx >= 10'd316 || fdy < 10'd4 || fdy >= 10'd236);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hs1 <= 1'b1; vs1 <= 1'b1; de1 <= 1'b0; sof1 <= 1'b0;
            o_hs <= 1'b1; o_vs <= 1'b1; o_de <= 1'b0; o_rgb565 <= 16'd0; o_sof <= 1'b0;
            x1<=0;y1<=0;o_x<=0;o_y<=0;boundary1<=0;o_frame_boundary<=0;
        end else begin
            hs1 <= (hc >= HSA); vs1 <= (vc >= VSA); de1 <= de; sof1 <= first && a_lock;
            o_hs <= hs1; o_vs <= vs1; o_de <= de1; o_sof <= sof1;
            o_rgb565 <= (de1 && t_de) ? (frame1 ? 16'hFFE0 : t_px) : 16'd0;
            x1<=px_x;y1<=px_y;o_x<=x1;o_y<=y1;
            boundary1<=fend;o_frame_boundary<=boundary1;
        end
    end
endmodule

// ----------------------------------------------------------------------------
// scan_layer — 单层字 FIFO 读出: 两项预取 + 帧描述字锁定 + 欠载降黑
//   use_layer=0: 本层整帧不取像素字(仍在 VBlank 内按描述字对齐并丢弃残留)
// ----------------------------------------------------------------------------
module scan_layer (
    input  wire        clk,
    input  wire        rst,
    input  wire        fend,
    input  wire        vact,
    input  wire        need,
    input  wire        odd,
    input  wire        use_layer,
    output wire        rd_en,
    input  wire [32:0] rd_data,
    input  wire        empty,
    output reg         locked,
    output reg         bad,
    output wire        have,
    output wire [32:0] q,
    output wire        dropped,
    output wire        underflow,
    output wire        lock_pulse
);
    reg [32:0] q0, q1;
    reg        v0, v1, pend;

    // 锁定: VBlank 内队首为描述字 => 本拍锁定并消耗它
    wire lock_now = !vact && !locked && v0 && q0[32];
    wire need_px  = need && locked && !bad && use_layer;
    assign have   = v0;
    wire pop_use  = need_px && odd && v0;
    wire pop_drop = !vact && !locked && v0 && !q0[32];
    wire pop      = pop_use || pop_drop || lock_now;
    wire [1:0] cnt_after = v0 + v1 + pend - pop;
    // 锁定后、本帧不用该层时不再读, 留待下一帧 VBlank 丢弃
    wire want     = !locked || (use_layer && !bad);
    assign rd_en  = !empty && want && (cnt_after < 2'd2) && !(v0 && v1);
    assign q      = q0;
    assign lock_pulse = lock_now;
    assign dropped   = pop_drop;
    assign underflow = need_px && !v0 && !bad;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            v0 <= 1'b0; v1 <= 1'b0; pend <= 1'b0; q0 <= 33'd0; q1 <= 33'd0;
        end else begin
            pend <= rd_en;
            case ({pop, pend})
            2'b10: begin q0 <= q1; v0 <= v1; v1 <= 1'b0; end
            2'b01: if (!v0) begin q0 <= rd_data; v0 <= 1'b1; end
                   else begin q1 <= rd_data; v1 <= 1'b1; end
            2'b11: if (v1) begin q0 <= q1; q1 <= rd_data; end
                   else begin q0 <= rd_data; end
            default: ;
            endcase
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin locked <= 1'b0; bad <= 1'b0; end
        else if (fend) begin locked <= 1'b0; bad <= 1'b0; end
        else begin
            if (lock_now) locked <= 1'b1;
            if (underflow) bad <= 1'b1;
        end
    end
endmodule
