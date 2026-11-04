`timescale 1ns / 1ps
// bmp_page_loader：将BMP文件字流转换、重采样为固定显示尺寸的行数据，按写通路和行环缓存余量提供背压。
module bmp_page_loader (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,            // 单拍: 新文件开始
    input  wire        in_valid,
    input  wire [31:0] in_data,          // 文件字节 {b0,b1,b2,b3}
    output wire        in_ready,

    output reg         row_valid,        // 一个输出字有效
    output reg  [31:0] row_data,
    output reg  [8:0]  row_y,            // 目标行号(显示顺序, 0=顶行)
    output reg         row_last,         // 该行最后一个字
    input  wire        row_ready,

    output reg         done,
    output reg         err,
    output wire [15:0] img_w,
    output wire [15:0] img_h
);
    // ---- 输入节流: 字间隔 >= 4 拍 ----
    reg [6:0] gap;
    reg [6:0] gap_need;
    wire      feed = in_valid && in_ready && running;
    wire      res_full;
    reg       running;
    wire      res_room;
    // 本图结束(含格式错误)后继续接收并丢弃剩余字(文件尾填充/错误文件), 上游可读完退出
    assign in_ready = !running || ((gap >= gap_need) && !res_full && (res_room || !geo_ok));

    always @(posedge clk or negedge rst_n)
        if (!rst_n) gap <= 7'd127;
        else if (feed) gap <= 7'd0;
        else if (gap != 7'd127) gap <= gap + 7'd1;

    // ---- 链路 ----
    wire [31:0] shim_data;
    wire        shim_valid;
    bmp_stream_align_shim u_shim (
        .clk(clk), .rst_n(rst_n), .stream_start(start),
        .raw_data(in_data), .raw_valid(feed), .align_ready(1'b1),
        .align_data(shim_data), .align_valid(shim_valid));

    wire        c_busy, c_done, c_ferr, c_serr, c_pv;
    wire [15:0] c_w, c_h, c_px;
    wire [12:0] c_x;
    wire [11:0] c_y;
    bmp24_to_rgb565_converter #(.MAX_WIDTH(16'd4096), .MAX_HEIGHT(16'd4096)) u_conv (
        .clk(clk), .rst_n(rst_n), .convert_start(start),
        .convert_busy(c_busy), .convert_done(c_done), .format_error(c_ferr), .size_error(c_serr),
        .data_in(shim_data), .data_valid(shim_valid),
        .image_width(c_w), .image_height(c_h),
        .pixel_out(c_px), .pixel_valid(c_pv), .pixel_x(c_x), .pixel_y(c_y));
    assign img_w = c_w;
    assign img_h = c_h;

    wire top_down;
    bmp_top_down_observer u_obs (
        .clk(clk), .rst_n(rst_n), .stream_start(start),
        .data_in(in_data), .accept(feed), .top_down(top_down));

    // 头部 14 字(54 字节)送完后第 3 拍几何有效(同 loader 端口级推断)
    reg [7:0] feed_cnt;
    reg       va, vb, geo_ok, res_start;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin feed_cnt <= 0; va <= 0; vb <= 0; end
        else if (start) begin feed_cnt <= 0; va <= 0; vb <= 0; end
        else begin
            if (shim_valid && feed_cnt != 8'd255) feed_cnt <= feed_cnt + 8'd1;
            va <= va || (feed_cnt >= 8'd14);
            vb <= vb || va;
        end
    end

    wire [10:0] r_x;
    wire [9:0]  r_y;
    wire [15:0] r_px;
    wire        r_v, r_done;
    bmp_resampler #(.DST_WIDTH(640), .DST_HEIGHT(480), .KEEP_ASPECT(1)) u_res (
        .clk(clk), .rst_n(rst_n), .frame_start(res_start),
        .src_width(c_w), .src_height(c_h),
        .in_x(c_x), .in_y(c_y), .in_pixel(c_px), .in_valid(c_pv && geo_ok),
        .out_x(r_x), .out_y(r_y), .out_pixel(r_px), .out_valid(r_v),
        .dn_full(res_full), .frame_done(r_done),
        .content_w(), .content_h(), .in_room(res_room));

    // ---- 2 行 ping-pong 行缓冲(320 字/行, 按 out_x 写半字) ----
    // 地址 {行选择, 字号[8:0]}: 每行占 512 项中的前 320 项
    reg [15:0] lb_lo [0:1023];  // 偶像素
    reg [15:0] lb_hi [0:1023];  // 奇像素
    reg [1:0]  full_v;          // 两行是否已满待取
    reg [8:0]  full_y [0:1];
    reg        wsel;            // 正在写的行
    reg        rsel;            // 正在取的行
    reg [8:0]  ridx;            // 0..320
    wire [8:0] y_disp = top_down ? r_y[8:0] : (9'd479 - r_y[8:0]);
    assign res_full = full_v[wsel];

    always @(posedge clk) if (r_v && !res_full) begin
        if (r_x[0]) lb_hi[{wsel, r_x[9:1]}] <= r_px;
        else        lb_lo[{wsel, r_x[9:1]}] <= r_px;
    end

    // 读口寄存一拍
    reg  [15:0] q_lo, q_hi;
    reg         rp;             // 读在途
    reg  [8:0]  rp_idx;
    wire        out_free  = !row_valid || row_ready;
    wire        can_rd    = full_v[rsel] && (ridx != 9'd320) && !rp && out_free;
    always @(posedge clk) begin
        q_lo <= lb_lo[{rsel, ridx[8:0]}];
        q_hi <= lb_hi[{rsel, ridx[8:0]}];
    end

    reg r_done_seen;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            full_v <= 2'b00; full_y[0] <= 0; full_y[1] <= 0; wsel <= 0; rsel <= 0; ridx <= 0;
            rp <= 0; rp_idx <= 0; row_valid <= 0; row_data <= 0; row_y <= 0; row_last <= 0;
            running <= 0; geo_ok <= 0; res_start <= 0; done <= 0; err <= 0; r_done_seen <= 0;
            gap_need <= 7'd4;
        end else begin
            done <= 1'b0; res_start <= 1'b0;
            if (row_valid && row_ready) row_valid <= 1'b0;

            if (start) begin
                running <= 1'b1; geo_ok <= 1'b0; err <= 1'b0; r_done_seen <= 1'b0; gap_need <= 7'd4;
                full_v <= 2'b00; wsel <= 0; rsel <= 0; ridx <= 0; rp <= 0;
            end else if (running) begin
                if (vb && !geo_ok && !err) begin
                    if (c_ferr || c_serr) begin err <= 1'b1; running <= 1'b0; done <= 1'b1; end
                    else begin
                        geo_ok <= 1'b1; res_start <= 1'b1;
                        // 放大倍率台阶(按源宽): 1x/2x/3x/4x 以上
                        gap_need <= (c_w >= 16'd640) ? 7'd4 : (c_w >= 16'd320) ? 7'd8 :
                                    (c_w >= 16'd214) ? 7'd12 : (c_w >= 16'd160) ? 7'd16 :
                                    (c_w >= 16'd107) ? 7'd24 : (c_w >= 16'd80) ? 7'd32 : 7'd96;
                    end
                end
                if (r_done && geo_ok) r_done_seen <= 1'b1;
            end

            // 行写满: 目标第 640 像素写入
            if (r_v && !res_full && r_x == 11'd639) begin
                full_v[wsel] <= 1'b1; full_y[wsel] <= y_disp; wsel <= ~wsel;
            end

            // 取行
            rp <= 1'b0;
            if (can_rd) begin rp <= 1'b1; rp_idx <= ridx; ridx <= ridx + 9'd1; end
            if (rp) begin
                row_valid <= 1'b1;
                row_data  <= {q_hi, q_lo};
                row_y     <= full_y[rsel];
                row_last  <= (rp_idx == 9'd319);
            end
            if (ridx == 9'd320 && !rp && !can_rd && out_free) begin
                full_v[rsel] <= 1'b0; rsel <= ~rsel; ridx <= 0;
            end

            if (running && r_done_seen && full_v == 2'b00 && !row_valid && !rp) begin
                running <= 1'b0; done <= 1'b1;
            end
        end
    end
endmodule
