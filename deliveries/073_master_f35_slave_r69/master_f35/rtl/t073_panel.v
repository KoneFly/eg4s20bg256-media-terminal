`timescale 1ns / 1ps
// t073_panel：面板同步、消抖和短长按识别。页面优先级为SW1设置、SW3视频、SW2音乐、默认图片；SW4无功能，按住时切页会取消该次按键。
module t073_panel #(
    parameter integer MS_CYCLES = 50_000,      // 1ms @50MHz
    parameter integer DEB_MS    = 20,
    parameter integer LONG_MS   = 1000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [3:0] sw,
    input  wire [2:0] keys_n,
    output reg  [3:0] sw_q,
    output wire [1:0] page,                    // 0 图片 1 WAV 2 视频 3 菜单
    output wire [1:0] tgt_mode,                // 0 图片 1 WAV 2 视频
    output wire [2:0] k_short,
    output wire [2:0] k_long
);
    reg [15:0] ms_cnt;
    wire       tick = (ms_cnt == MS_CYCLES - 1);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) ms_cnt <= 16'd0;
        else ms_cnt <= tick ? 16'd0 : ms_cnt + 16'd1;

    // ---- 拨码 ----
    (* async_reg = "true" *) reg [3:0] sw_m, sw_s;
    reg [3:0] sw_c;
    reg [4:0] sw_n;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin sw_m <= 4'd0; sw_s <= 4'd0; sw_c <= 4'd0; sw_n <= 5'd0; sw_q <= 4'd0; end
        else begin
            sw_m <= sw; sw_s <= sw_m;
            if (sw_s != sw_c) begin sw_c <= sw_s; sw_n <= 5'd0; end
            else if (sw_c == sw_q) sw_n <= 5'd0;
            else if (tick) begin
                if (sw_n == DEB_MS - 1) begin sw_q <= sw_c; sw_n <= 5'd0; end
                else sw_n <= sw_n + 5'd1;
            end
        end
    assign page     = sw_q[0] ? 2'd3 : sw_q[2] ? 2'd2 : sw_q[1] ? 2'd1 : 2'd0;
    assign tgt_mode = sw_q[2] ? 2'd2 : sw_q[1] ? 2'd1 : 2'd0;

    // ---- 按键 ----
    genvar k;
    generate for (k = 0; k < 3; k = k + 1) begin : g_key
        (* async_reg = "true" *) reg km, ks;
        reg       kc, dn, armed, fired, ev_s, ev_l;
        reg [4:0] kn;
        reg [9:0] hold;
        reg [1:0] owner;
        always @(posedge clk or negedge rst_n)
            if (!rst_n) begin
                km <= 1'b1; ks <= 1'b1; kc <= 1'b0; kn <= 5'd0; dn <= 1'b0;
                armed <= 1'b0; fired <= 1'b0; hold <= 10'd0; owner <= 2'd0;
                ev_s <= 1'b0; ev_l <= 1'b0;
            end else begin
                km <= keys_n[k]; ks <= km;
                ev_s <= 1'b0; ev_l <= 1'b0;
                // 消抖: kc 为候选按下电平
                if (!ks != kc) begin kc <= !ks; kn <= 5'd0; end
                else if (kc == dn) kn <= 5'd0;
                else if (tick) begin
                    if (kn == DEB_MS - 1) begin
                        dn <= kc; kn <= 5'd0;
                        if (kc) begin armed <= 1'b1; fired <= 1'b0; hold <= 10'd0; owner <= page; end
                        else begin
                            if (armed && !fired) ev_s <= 1'b1;
                            armed <= 1'b0;
                        end
                    end else kn <= kn + 5'd1;
                end
                if (dn) begin
                    if (page != owner) armed <= 1'b0;
                    if (tick && hold != LONG_MS - 1) hold <= hold + 10'd1;
                    if (hold == LONG_MS - 1 && armed && !fired && kc) begin ev_l <= 1'b1; fired <= 1'b1; end
                end
            end
        assign k_short[k] = ev_s;
        assign k_long[k]  = ev_l;
    end endgenerate
endmodule
