`timescale 1ns / 1ps
// UDP应用域诊断；只统计接口事实，不将ack或载荷计数冒充线上发送。
module v7_udp_pcm_diag (
    input wire clk, input wire rst, input wire ms_tick, input wire [2:0] page_sel,
    input wire frame_ready, input wire prepared, input wire active,
    input wire ready, input wire request, input wire ack, input wire tx_valid,
    input wire rx_valid, input wire tx_take, input wire tx_sof_n,
    input wire rx_take, input wire fault, input wire ip_error_raw, input wire arp_error_raw,
    output reg [15:0] value, output wire rx_recent
);
    reg request_d, ack_d, tx_valid_d, rx_valid_d;
    reg [15:0] request_count, ack_count, tx_count, mac_count, rx_count, ack_edges;
    reg [9:0] seen;
    reg [8:0] tx_bytes;
    reg waiting_first;
    reg [15:0] delay_count, first_delay;
    reg [9:0] rx_ms;
    wire complete = tx_valid_d && !tx_valid && (tx_bytes == 9'd292);
    wire bad_burst = tx_valid_d && !tx_valid && (tx_bytes != 9'd292);
    assign rx_recent = (rx_ms != 10'd0);
    always @(posedge clk) begin
        if (rst) begin
            request_d <= 0; ack_d <= 0; tx_valid_d <= 0; rx_valid_d <= 0;
            request_count <= 0; ack_count <= 0; tx_count <= 0;
            mac_count <= 0; rx_count <= 0; ack_edges <= 0;
            seen <= 0; tx_bytes <= 0; waiting_first <= 0;
            delay_count <= 0; first_delay <= 0; rx_ms <= 0;
        end else begin
            request_d <= request; ack_d <= ack;
            tx_valid_d <= tx_valid; rx_valid_d <= rx_valid;
            if (request && !request_d) request_count <= request_count + 16'd1;
            if (request && ack) ack_count <= ack_count + 16'd1;
            if (ack && !ack_d) ack_edges <= ack_edges + 16'd1;
            if (complete) tx_count <= tx_count + 16'd1;
            if (tx_take && !tx_sof_n) mac_count <= mac_count + 16'd1;
            if (rx_valid && !rx_valid_d) rx_count <= rx_count + 16'd1;
            seen <= seen | {fault | bad_burst, rx_take, tx_take, rx_valid,
                            complete, tx_valid, request && ack, request, prepared, frame_ready};
            if (tx_valid) begin
                if (!tx_valid_d) tx_bytes <= 9'd1;
                else if (tx_bytes != 9'h1ff) tx_bytes <= tx_bytes + 9'd1;
            end
            if (request && ack) begin
                waiting_first <= 1'b1;
                delay_count <= 16'd0;
            end else if (waiting_first) begin
                if (tx_valid) begin
                    first_delay <= (delay_count == 16'hffff) ? 16'hffff : delay_count + 16'd1;
                    waiting_first <= 1'b0;
                end else if (delay_count != 16'hffff) delay_count <= delay_count + 16'd1;
            end
            if (rx_valid) rx_ms <= 10'd1000;
            else if (ms_tick && (rx_ms != 0)) rx_ms <= rx_ms - 10'd1;
        end
    end
    always @(*) begin
        case (page_sel)
            3'd0: value = {arp_error_raw, ip_error_raw, ack, active, request, ready, seen};
            3'd1: value = request_count;
            3'd2: value = ack_count;
            3'd3: value = tx_count;
            3'd4: value = mac_count;
            3'd5: value = rx_count;
            3'd6: value = ack_edges;
            default: value = first_delay;
        endcase
    end
endmodule
