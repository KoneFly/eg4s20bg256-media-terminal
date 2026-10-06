`timescale 1ns/1ps
// 每帧步进一像素；仅文案模式变化重启，普通仪表盘银行刷新不打断滚动。
module help_marquee(
    input wire clk,input wire rst,input wire frame_tick,input wire content_valid,
    input wire bank_commit,input wire ready_adjust,
    output reg [10:0] offset
);
    reg adjust;
    wire [10:0] last_offset=adjust?11'd880:11'd1632;
    always @(posedge clk or posedge rst) begin
        if(rst) begin offset<=11'd0;adjust<=1'b0;end
        else if(bank_commit && ready_adjust!=adjust) begin
            adjust<=ready_adjust;offset<=11'd0;
        end else if(frame_tick && content_valid) begin
            if(offset>=last_offset)offset<=11'd0;
            else offset<=offset+11'd1;
        end
    end
endmodule
