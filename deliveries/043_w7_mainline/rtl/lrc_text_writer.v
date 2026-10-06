`timescale 1ns/1ps
// 字节写入的toggle/ack握手：数据保持到确认，等待请求释放以防重复受理。
module lrc_text_writer(
    input wire pixel_clk,input wire pixel_rst,input wire request,input wire [12:0] address,
    input wire [7:0] data,input wire [7:0] epoch,output reg acknowledge,
    input wire ctrl_clk,input wire ctrl_rst,input wire accept_write,input wire [7:0] expected_epoch,
    output wire write_enable,output wire [12:0] write_address,output wire [7:0] write_data
);
    reg request_toggle,ack_toggle;
    reg [28:0] payload;
    reg [1:0] state;
    (* async_reg="true" *) reg [1:0] ack_sync,request_sync;
    wire pending=request_sync[1]!=ack_toggle;
    assign write_enable=pending && accept_write && payload[28:21]==expected_epoch;
    assign write_address=payload[20:8];assign write_data=payload[7:0];
    always @(posedge pixel_clk or posedge pixel_rst)begin
        if(pixel_rst)begin request_toggle<=0;payload<=0;state<=0;ack_sync<=0;acknowledge<=0;end
        else begin
            ack_sync<={ack_sync[0],ack_toggle};acknowledge<=0;
            case(state)
                0:if(request)begin payload<={epoch,address,data};request_toggle<=~request_toggle;state<=1;end
                1:if(ack_sync[1]==request_toggle)begin acknowledge<=1;state<=2;end
                default:if(!request)state<=0;
            endcase
        end
    end
    always @(posedge ctrl_clk or posedge ctrl_rst)begin
        if(ctrl_rst)begin request_sync<=0;ack_toggle<=0;end
        else begin request_sync<={request_sync[0],request_toggle};if(pending)ack_toggle<=request_sync[1];end
    end
endmodule
