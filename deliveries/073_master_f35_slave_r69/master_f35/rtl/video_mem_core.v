`timescale 1ns / 1ps
// video_mem_core：SDRAM帧存储、显示DMA和图像/视频写通路。完整重启时旧帧内容失效，重新初始化和加载。
module video_mem_core #(
    parameter integer T_INIT       = 10000,
    parameter integer TRANS_FRAMES = 30
)(
    input  wire        clk,
    input  wire        sdram_clk,
    input  wire        rst_n,
    input  wire        pix_clk,
    input  wire        pix_rst,
    input  wire        mode_video,
    output reg         mode_eff,
    input  wire        v_clear,
    input  wire        v_pause,
    output wire        v_paused,
    output wire        v_disp_valid,

    input  wire [5:0]  content_fps,
    input  wire        in_valid,
    input  wire [31:0] in_data,
    output wire        in_ready,

    input  wire [1:0]  img_page,
    input  wire        img_valid,
    input  wire [31:0] img_data,
    input  wire [8:0]  img_y,
    output wire        img_ready,
    output wire        img_idle,
    input  wire        show_req,
    input  wire [1:0]  show_page,
    input  wire [2:0]  show_mode,
    input  wire [1:0]  zoom,
    input  wire [1:0]  wall_cell,
    input  wire [2:0]  thumb_slot,
    input  wire        blank_start,
    output wire        blank_busy,
    output wire        trans_busy,

    output wire        o_hs,
    output wire        o_vs,
    output wire        o_de,
    output wire [15:0] o_rgb565,
    output wire        o_sof,
    output wire [9:0]  o_x,o_y,
    output wire        o_frame_boundary,

    output wire        init_done,
    output wire [15:0] repeat_cnt,
    output wire [15:0] shown_cnt,
    output wire [15:0] dma_late_cnt,
    output wire [15:0] underflow_cnt,
    output wire [15:0] seek_drop_cnt,
    output wire        ref_overrun
);
    localparam [20:0] PW = 21'd153600;

    // ---- 引擎 ----
    wire        e_valid, e_ready, e_write, e_layer_b, wr_pop, wr_pop_last, rd_valid, rd_last;
    wire [20:0] e_addr;
    wire [8:0]  e_len;
    wire [2:0]  wr_pop_tag, rd_tag;
    wire [31:0] wr_data, rd_data;

    wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
    wire [10:0] sa;
    wire [1:0]  sba;
    wire [3:0]  sdm;
    wire [31:0] dq_out, sdram_dq;
    reg  [31:0] dq_m;

    // tag[0] 标记读属于 B 层, 读数据按 rd_tag 分发
    sdr_engine2 #(.T_INIT(T_INIT)) u_eng (
        .clk(clk), .rst_n(rst_n), .init_done(init_done),
        .req_valid(e_valid), .req_ready(e_ready), .req_write(e_write),
        .req_addr(e_addr), .req_len(e_len), .req_tag({2'b00, e_layer_b}),
        .wr_pop(wr_pop), .wr_pop_tag(wr_pop_tag), .wr_pop_last(wr_pop_last),
        .wr_data(wr_data), .wr_be(4'hF),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_tag(rd_tag), .rd_last(rd_last),
        .ref_overrun(ref_overrun),
        .sdr_cke(cke), .sdr_cs_n(cs_n), .sdr_ras_n(ras_n), .sdr_cas_n(cas_n),
        .sdr_we_n(we_n), .sdr_addr(sa), .sdr_ba(sba), .sdr_dm(sdm),
        .sdr_dq_out(dq_out), .sdr_dq_oe(dq_oe), .sdr_dq_in(dq_m));

    EG_PHY_SDRAM_2M_32 u_sdram (
        .clk(sdram_clk), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .addr(sa), .ba(sba), .dq(sdram_dq), .cs_n(cs_n),
        .dm0(sdm[0]), .dm1(sdm[1]), .dm2(sdm[2]), .dm3(sdm[3]), .cke(cke));
    assign sdram_dq = dq_oe ? dq_out : 32'bz;

    // 读回 DQ 在 sdram_clk 域预捕获一级, 引擎 DQ_LAT=1 补偿
    always @(posedge sdram_clk) dq_m <= sdram_dq;

    // ---- 仲裁 ----
    wire        a_valid, a_urgent, a_grant, b_valid, b_urgent, b_grant, w_valid, w_grant;
    wire [20:0] a_addr, b_addr, w_addr;
    wire [8:0]  a_len, b_len, w_len;

    sdr_arbiter u_arb (
        .clk(clk), .rst_n(rst_n),
        .a_valid(a_valid & init_done), .a_urgent(a_urgent), .a_addr(a_addr), .a_len(a_len), .a_grant(a_grant),
        .b_valid(b_valid & init_done), .b_urgent(b_urgent), .b_addr(b_addr), .b_len(b_len), .b_grant(b_grant),
        .w_valid(w_valid & init_done), .w_addr(w_addr), .w_len(w_len), .w_grant(w_grant),
        .e_valid(e_valid), .e_ready(e_ready), .e_write(e_write), .e_addr(e_addr), .e_len(e_len),
        .e_layer_b(e_layer_b));

    wire        vw_grant;
    reg         vclr_q;
    // ---- 视频页管理 ----
    wire        fill_req, fill_grant, fill_commit, v_scan_req, v_scan_ack, v_scan_valid;
    wire [1:0]  fill_page;
    wire [20:0] fill_base, v_scan_base;

    frame_page_mgr u_pages (
        .clk(clk), .rst_n(rst_n), .fps(content_fps),
        .clear(vclr_q), .pause_req(v_pause), .paused(v_paused),
        .fill_req(fill_req && mode_eff), .fill_grant(fill_grant), .fill_page(fill_page),
        .fill_base(fill_base), .fill_commit(fill_commit),
        .scan_req(v_scan_req), .scan_ack(v_scan_ack), .scan_base(v_scan_base), .scan_valid(v_scan_valid),
        .disp_valid(v_disp_valid), .repeat_cnt(repeat_cnt), .shown_cnt(shown_cnt));

    // ---- 写通路: 视频 / 图片 ----
    wire        vw_valid, vw_pop, vw_last;
    wire [20:0] vw_addr;
    wire [8:0]  vw_len;
    wire [31:0] vw_data;
    video_wr_path u_wr (
        .clk(clk), .rst_n(rst_n), .clear(vclr_q),
        .in_valid(in_valid && mode_eff), .in_data(in_data), .in_ready(in_ready),
        .fill_req(fill_req), .fill_grant(fill_grant), .fill_base(fill_base),
        .fill_commit(fill_commit),
        .w_valid(vw_valid), .w_addr(vw_addr), .w_len(vw_len), .w_grant(vw_grant),
        .wr_pop(vw_pop), .wr_pop_last(vw_last), .wr_data(vw_data));

    wire        iw_valid, iw_grant, iw_pop, iw_last;
    wire [20:0] iw_addr;
    wire [8:0]  iw_len;
    wire [31:0] iw_data;
    // 黑缩略填充: 逐行送零, 与加载器互斥(调用方在加载器空闲时发起)
    reg        bk_on;
    reg [8:0]  bk_y;
    reg [8:0]  bk_x;
    wire       iw_in_ready;
    assign blank_busy = bk_on;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin bk_on <= 1'b0; bk_y <= 9'd0; bk_x <= 9'd0; end
        else if (blank_start) begin bk_on <= 1'b1; bk_y <= 9'd0; bk_x <= 9'd0; end
        else if (bk_on && iw_in_ready) begin
            if (bk_x == 9'd319) begin
                bk_x <= 9'd0; bk_y <= bk_y + 9'd1;
                if (bk_y == 9'd479) bk_on <= 1'b0;
            end else bk_x <= bk_x + 9'd1;
        end
    assign img_ready = iw_in_ready && !bk_on;
    wire [20:0] thumb_base = (thumb_slot[2] ? PW * 21'd6 : PW * 21'd5) +
                             (thumb_slot[1] ? 21'd76800 : 21'd0) + (thumb_slot[0] ? 21'd160 : 21'd0);
    img_wr_path u_iwr (
        .clk(clk), .rst_n(rst_n), .page_base(PW * (21'd3 + {19'd0, img_page})),
        .thumb_en(1'b1), .thumb_base(thumb_base),
        .in_valid(bk_on || (img_valid && !mode_eff)), .in_data(bk_on ? 32'd0 : img_data),
        .in_y(bk_on ? bk_y : img_y), .in_ready(iw_in_ready),
        .w_valid(iw_valid), .w_addr(iw_addr), .w_len(iw_len), .w_grant(iw_grant),
        .wr_pop(iw_pop), .wr_pop_last(iw_last), .wr_data(iw_data), .idle(img_idle));

    // 写端口归属按事务记录(引擎按序取数, 模式切换时在途写仍归原通路)
    reg        wsel_q [0:3];
    reg [1:0]  wq_w, wq_r;
    wire       w_is_img = !mode_eff;
    assign w_valid  = w_is_img ? iw_valid : vw_valid;
    assign w_addr   = w_is_img ? iw_addr  : vw_addr;
    assign w_len    = w_is_img ? iw_len   : vw_len;
    assign vw_grant = w_grant && !w_is_img;
    assign iw_grant = w_grant &&  w_is_img;
    wire   pop_img  = wsel_q[wq_r];
    assign vw_pop   = wr_pop && !pop_img;
    assign iw_pop   = wr_pop &&  pop_img;
    assign vw_last  = wr_pop_last && !pop_img;
    assign iw_last  = wr_pop_last &&  pop_img;
    reg    pop_img_d;
    always @(posedge clk) pop_img_d <= pop_img;
    assign wr_data  = pop_img_d ? iw_data : vw_data;
    integer n;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin wq_w <= 2'd0; wq_r <= 2'd0; for (n = 0; n < 4; n = n + 1) wsel_q[n] <= 1'b0; end
        else begin
            if (w_grant) begin wsel_q[wq_w] <= w_is_img; wq_w <= wq_w + 2'd1; end
            if (wr_pop_last) wq_r <= wq_r + 2'd1;
        end

    // 视频写通路在途事务数(已授权未取完) 与清空释放
    reg [2:0] vq_cnt;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin vq_cnt <= 3'd0; vclr_q <= 1'b1; end
        else begin
            vq_cnt <= vq_cnt + {2'd0, vw_grant} - {2'd0, wr_pop_last && !pop_img};
            if (v_clear) vclr_q <= 1'b1;
            else if (vq_cnt == 3'd0) vclr_q <= 1'b0;
        end

    // ---- 层控制 ----
    wire        a_scan_req, a_scan_ack, a_scan_valid, b_scan_req, b_scan_ack, b_scan_valid, shown;
    wire [20:0] a_scan_base, b_scan_base;
    wire [31:0] a_scan_desc, b_scan_desc;
    wire [1:0]  cur_page;
    layer_ctrl #(.PAGE_WORDS(PW), .TRANS_FRAMES(TRANS_FRAMES)) u_lc (
        .clk(clk), .rst_n(rst_n), .mode_video(mode_eff),
        .v_scan_req(v_scan_req), .v_scan_ack(v_scan_ack), .v_scan_base(v_scan_base), .v_scan_valid(v_scan_valid),
        .show_req(show_req), .show_page(show_page), .show_mode(show_mode),
        .zoom(zoom), .wall_cell(wall_cell),
        .trans_busy(trans_busy), .shown(shown), .cur_page(cur_page),
        .a_scan_req(a_scan_req), .a_scan_ack(a_scan_ack), .a_scan_base(a_scan_base),
        .a_scan_valid(a_scan_valid), .a_scan_desc(a_scan_desc),
        .b_scan_req(b_scan_req), .b_scan_ack(b_scan_ack), .b_scan_base(b_scan_base),
        .b_scan_valid(b_scan_valid), .b_scan_desc(b_scan_desc));

    always @(posedge clk or negedge rst_n)
        if (!rst_n) mode_eff <= 1'b0;
        else if (a_scan_ack) mode_eff <= mode_video;

    // ---- 两层 DMA + 异步 FIFO ----
    wire        frame_tog;
    wire        a_fwe, b_fwe, a_rde, b_rde, a_emp, b_emp, a_full, b_full;
    wire [32:0] a_fwd, b_fwd, a_frd, b_frd;
    wire [10:0] a_lvl, b_lvl;
    wire [15:0] a_late, b_late;
    assign dma_late_cnt = a_late + b_late;

    display_dma u_dma_a (
        .clk(clk), .rst_n(rst_n), .frame_tog(frame_tog),
        .scan_req(a_scan_req), .scan_ack(a_scan_ack), .scan_base(a_scan_base),
        .scan_valid(a_scan_valid), .scan_desc(a_scan_desc),
        .r_valid(a_valid), .r_urgent(a_urgent), .r_addr(a_addr), .r_len(a_len), .r_grant(a_grant),
        .rd_valid(rd_valid && !rd_tag[0]), .rd_data(rd_data),
        .fifo_wr_en(a_fwe), .fifo_wr_data(a_fwd), .fifo_level(a_lvl), .late_cnt(a_late));
    display_dma u_dma_b (
        .clk(clk), .rst_n(rst_n), .frame_tog(frame_tog),
        .scan_req(b_scan_req), .scan_ack(b_scan_ack), .scan_base(b_scan_base),
        .scan_valid(b_scan_valid), .scan_desc(b_scan_desc),
        .r_valid(b_valid), .r_urgent(b_urgent), .r_addr(b_addr), .r_len(b_len), .r_grant(b_grant),
        .rd_valid(rd_valid && rd_tag[0]), .rd_data(rd_data),
        .fifo_wr_en(b_fwe), .fifo_wr_data(b_fwd), .fifo_level(b_lvl), .late_cnt(b_late));

    async_word_fifo #(.DW(33), .DEPTH(1024)) u_fifo_a (
        .wr_clk(clk), .wr_rst_n(rst_n), .wr_en(a_fwe), .wr_data(a_fwd), .full(a_full), .wr_level(a_lvl),
        .rd_clk(pix_clk), .rd_rst_n(~pix_rst), .rd_en(a_rde), .rd_data(a_frd), .empty(a_emp));
    async_word_fifo #(.DW(33), .DEPTH(1024)) u_fifo_b (
        .wr_clk(clk), .wr_rst_n(rst_n), .wr_en(b_fwe), .wr_data(b_fwd), .full(b_full), .wr_level(b_lvl),
        .rd_clk(pix_clk), .rd_rst_n(~pix_rst), .rd_en(b_rde), .rd_data(b_frd), .empty(b_emp));

    video_scan_out u_scan (
        .clk(pix_clk), .rst(pix_rst), .frame_tog(frame_tog),
        .a_rd_en(a_rde), .a_rd_data(a_frd), .a_empty(a_emp),
        .b_rd_en(b_rde), .b_rd_data(b_frd), .b_empty(b_emp),
        .o_hs(o_hs), .o_vs(o_vs), .o_de(o_de), .o_rgb565(o_rgb565), .o_sof(o_sof),
        .o_x(o_x),.o_y(o_y),.o_frame_boundary(o_frame_boundary),
        .underflow_cnt(underflow_cnt), .seek_drop_cnt(seek_drop_cnt));
endmodule
