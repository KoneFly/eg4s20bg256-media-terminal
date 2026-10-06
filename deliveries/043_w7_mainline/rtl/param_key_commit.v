`timescale 1ns/1ps
// 参数快照: 两级同步请求后捕获源域保持的总线，仅在vsync帧首换装。
module param_key_commit (
    input wire I_clk,
    input wire I_rst,
    input wire I_vs,
    input wire request_toggle,
    input wire [3:0] gear_snapshot,
    output reg ack_toggle,
    output wire [7:0] O_bri_off,
    output wire [1:0] O_con_sel,
    output reg [1:0] O_bri_gear,
    output reg [1:0] O_con_gear,
    output reg O_param_upd
);
    (* async_reg = "true" *) reg [1:0] request_sync;
    reg [3:0] pending;
    reg vs_d;
    wire vs_fall = vs_d && !I_vs;
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            request_sync <= 2'b00;
            ack_toggle <= 1'b0;
            pending <= {2'd1, 2'd0};
            vs_d <= 1'b1;
            O_bri_gear <= 2'd0;
            O_con_gear <= 2'd1;
            O_param_upd <= 1'b0;
        end else begin
            request_sync <= {request_sync[0], request_toggle};
            vs_d <= I_vs;
            O_param_upd <= 1'b0;
            if (request_sync[1] != ack_toggle) begin
                pending <= gear_snapshot;
                ack_toggle <= request_sync[1];
            end
            if (vs_fall && pending != {O_con_gear, O_bri_gear}) begin
                O_bri_gear <= pending[1:0];
                O_con_gear <= pending[3:2];
                O_param_upd <= 1'b1;
            end
        end
    end
    assign O_bri_off = {1'b0, O_bri_gear, 5'b0};
    assign O_con_sel = O_con_gear;
endmodule
