`timescale 1ns / 1ps
// request为发送控制器的寄存输出；ready_d对应使其上升的决策沿。
// 同时保留下一采样沿的ready，区分正常撤ready与未ready起包。
module v7_ready_probe #(parameter [15:0] BUILD_CODE=16'd5207) (
    input wire clk, rst, ms_tick, input wire [2:0] page_sel,
    input wire ready, request, ack, ip_error_raw, arp_error_raw,
    output reg [15:0] value
);
    reg ready_d, request_d;
    reg launch_seen, launch_ready, visible_ready;
    reg [15:0] bad_launch_count, wait_ms, ready_edges;
    always @(posedge clk) begin
        if(rst) begin
            ready_d<=0; request_d<=0; launch_seen<=0; launch_ready<=0; visible_ready<=0;
            bad_launch_count<=0; wait_ms<=0; ready_edges<=0;
        end else begin
            ready_d<=ready;
            request_d<=request;
            if(ready && !ready_d && ready_edges!=16'hffff) ready_edges<=ready_edges+16'd1;
            if(request && !request_d) begin
                launch_seen<=1;
                launch_ready<=ready_d;
                visible_ready<=ready;
                if(!ready_d && bad_launch_count!=16'hffff) bad_launch_count<=bad_launch_count+16'd1;
            end
            if(!request || ack) wait_ms<=0;
            else if(ms_tick && wait_ms!=16'hffff) wait_ms<=wait_ms+16'd1;
        end
    end
    always @(*) begin
        case(page_sel)
            0: value={15'd0,ready};
            1: value=launch_seen ? {15'd0,launch_ready} : 16'd9;
            2: value=launch_seen ? {15'd0,visible_ready} : 16'd9;
            3: value=bad_launch_count;
            4: value=wait_ms;
            5: value=(ip_error_raw ? 16'd10 : 16'd0)+(arp_error_raw ? 16'd1 : 16'd0);
            6: value=ready_edges;
            default: value=BUILD_CODE;
        endcase
    end
endmodule
