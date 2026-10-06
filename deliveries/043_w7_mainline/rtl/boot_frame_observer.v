`timescale 1ns / 1ps
// 首图观测：ctrl 请求经 toggle/ack 跨域，pixel 域从 SOF 计满一帧握手。
// 终点是 HDMI IP 接受最后一个像素；显示器实际呈现仍需板测确认。
module boot_frame_observer #(
    parameter integer FRAME_PIXELS = 640 * 480
)(
    input wire ctrl_clk,
    input wire ctrl_rst_n,
    input wire request_toggle,
    output wire complete_toggle,
    input wire pixel_clk,
    input wire pixel_rst,
    input wire axis_valid,
    input wire axis_ready,
    input wire axis_sof
);
    localparam integer COUNT_WIDTH = $clog2(FRAME_PIXELS + 1);
    localparam integer LAST_VALUE = FRAME_PIXELS - 1;
    localparam [COUNT_WIDTH-1:0] LAST_COUNT = LAST_VALUE[COUNT_WIDTH-1:0];
    (* async_reg = "true" *) reg [1:0] request_sync;
    (* async_reg = "true" *) reg [1:0] complete_sync;
    reg acknowledge;
    reg counting;
    reg [COUNT_WIDTH-1:0] accepted;
    wire advance = axis_valid && axis_ready;

    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst) begin
            request_sync <= 2'b00;
            acknowledge <= 1'b0;
            counting <= 1'b0;
            accepted <= {COUNT_WIDTH{1'b0}};
        end else begin
            request_sync <= {request_sync[0], request_toggle};
            if (advance && axis_sof) begin
                counting <= (request_sync[1] != acknowledge);
                accepted <= {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
            end else if (advance && counting) begin
                if (accepted == LAST_COUNT) begin
                    acknowledge <= request_sync[1];
                    counting <= 1'b0;
                end else begin
                    accepted <= accepted + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                end
            end
        end
    end

    always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            complete_sync <= 2'b00;
        else
            complete_sync <= {complete_sync[0], acknowledge};
    end
    assign complete_toggle = complete_sync[1];
endmodule
