`timescale 1ns / 1ps
// ============================================================================
// sdr_arbiter — 两路显示读(A/B 层) + 一路写 的事务级仲裁
//
// 引擎一次只接收一个事务, 仲裁只在引擎 req_ready 时决定:
//   1. 任一读层 FIFO 低于水位(urgent): 该层优先(两层都急则轮转);
//   2. 否则三路轮转(上次授权者之后的下一个有请求者), 写不会被读长期压住,
//      读也不会被写压住(读请求受各自 FIFO 空间自然节流)。
// 客户端请求为电平 valid, grant 为单拍接受脉冲。
// ============================================================================
module sdr_arbiter (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        a_valid,
    input  wire        a_urgent,
    input  wire [20:0] a_addr,
    input  wire [8:0]  a_len,
    output wire        a_grant,

    input  wire        b_valid,
    input  wire        b_urgent,
    input  wire [20:0] b_addr,
    input  wire [8:0]  b_len,
    output wire        b_grant,

    input  wire        w_valid,
    input  wire [20:0] w_addr,
    input  wire [8:0]  w_len,
    output wire        w_grant,

    output wire        e_valid,
    input  wire        e_ready,
    output wire        e_write,
    output wire [20:0] e_addr,
    output wire [8:0]  e_len,
    output wire        e_layer_b          // 被选中的读属于 B 层(读数据按序归属)
);
    reg [1:0] last;                       // 0=A 1=B 2=W

    wire ua = a_valid && a_urgent;
    wire ub = b_valid && b_urgent;

    // 轮转顺序: last 之后依次 A -> B -> W -> A
    reg [1:0] rr;
    always @(*) begin
        case (last)
        2'd0:    rr = b_valid ? 2'd1 : w_valid ? 2'd2 : 2'd0;
        2'd1:    rr = w_valid ? 2'd2 : a_valid ? 2'd0 : 2'd1;
        default: rr = a_valid ? 2'd0 : b_valid ? 2'd1 : 2'd2;
        endcase
    end

    wire [1:0] pick = (ua && ub) ? ((last == 2'd0) ? 2'd1 : 2'd0) :
                      ua ? 2'd0 : ub ? 2'd1 : rr;

    assign e_valid   = a_valid || b_valid || w_valid;
    assign e_write   = (pick == 2'd2);
    assign e_layer_b = (pick == 2'd1);
    assign e_addr    = (pick == 2'd0) ? a_addr : (pick == 2'd1) ? b_addr : w_addr;
    assign e_len     = (pick == 2'd0) ? a_len  : (pick == 2'd1) ? b_len  : w_len;
    assign a_grant   = e_ready && a_valid && (pick == 2'd0);
    assign b_grant   = e_ready && b_valid && (pick == 2'd1);
    assign w_grant   = e_ready && w_valid && (pick == 2'd2);

    always @(posedge clk or negedge rst_n)
        if (!rst_n) last <= 2'd2;
        else if (a_grant) last <= 2'd0;
        else if (b_grant) last <= 2'd1;
        else if (w_grant) last <= 2'd2;
endmodule
