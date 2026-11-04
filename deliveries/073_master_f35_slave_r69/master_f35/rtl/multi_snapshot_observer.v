`timescale 1ns/1ps
// 完整扫描已发布的每一路谱；原有level/有效性/bank/epoch/end观测均保留。
module multi_snapshot_observer(
    input wire clk,rst_n,
    input wire [7:0] level,
    input wire valid,bank,
    input wire [1:0] paths,
    input wire [31:0] epoch,end_sample,
    output reg [8:0] address,
    output wire serial_bit
);
    reg [75:0] shadow;
    reg [6:0] bit_index;
    wire [8:0] last_address=paths==2'd3 ? 9'd383 : paths==2'd2 ? 9'd255 : 9'd127;
    assign serial_bit=shadow[bit_index];
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin address<=0;shadow<=0;bit_index<=0;end
        else begin
            if(address>=last_address)begin
                address<=0;
                bit_index<=bit_index==7'd75 ? 7'd0 : bit_index+7'd1;
            end else address<=address+9'd1;
            shadow<={paths,level,valid,bank,epoch,end_sample};
        end
    end
endmodule
