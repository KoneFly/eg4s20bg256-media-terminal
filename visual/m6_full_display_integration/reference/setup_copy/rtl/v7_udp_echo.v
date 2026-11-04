`timescale 1ns / 1ps

// v7 空壳应用：把 UDP 载荷完整缓存后原样回发。
// 该模块只验证 UDP 应用接口，不承载 PCM 业务语义。
module v7_udp_echo #(
    parameter [15:0] BUFFER_BYTES = 16'd1024
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        app_rx_data_valid,
    input  wire [7:0]  app_rx_data,
    input  wire [15:0] app_rx_data_length,
    input  wire        app_tx_ack,
    output reg         app_tx_data_request,
    output reg         app_tx_data_valid,
    output reg  [7:0]  app_tx_data,
    output reg  [15:0] udp_data_length
);
    localparam integer PTR_WIDTH = $clog2(BUFFER_BYTES);
    localparam [15:0] BUFFER_LIMIT = BUFFER_BYTES;
    localparam [1:0] S_IDLE = 2'd0, S_WAIT_ACK = 2'd1, S_SEND = 2'd2;

    reg [7:0]  buffer [0:BUFFER_BYTES-1];
    reg [15:0] rx_count;
    reg [15:0] rx_length;
    reg [15:0] tx_count;
    reg [1:0] state;
    reg rx_seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_count <= 0;
            rx_length <= 0;
            rx_seen <= 1'b0;
        end else if (app_rx_data_valid) begin
            if (rx_count < BUFFER_LIMIT) begin
                buffer[rx_count[PTR_WIDTH-1:0]] <= app_rx_data;
                rx_count <= rx_count + 1'b1;
            end
            if (!rx_seen) begin
                rx_length <= (app_rx_data_length <= BUFFER_LIMIT) ? app_rx_data_length : BUFFER_LIMIT;
                rx_seen <= 1'b1;
            end
        end else if (state == S_SEND && tx_count >= rx_length) begin
            rx_count <= 0;
            rx_seen <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            tx_count <= 0;
            app_tx_data_request <= 1'b0;
            app_tx_data_valid <= 1'b0;
            app_tx_data <= 8'd0;
            udp_data_length <= 16'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    app_tx_data_request <= 1'b0;
                    app_tx_data_valid <= 1'b0;
                    tx_count <= 0;
                    if (rx_seen && !app_rx_data_valid && (rx_length != 0)) begin
                        udp_data_length <= rx_length;
                        app_tx_data_request <= 1'b1;
                        state <= S_WAIT_ACK;
                    end
                end
                S_WAIT_ACK: begin
                    if (app_tx_ack) begin
                        app_tx_data_request <= 1'b0;
                        tx_count <= 0;
                        state <= S_SEND;
                    end
                end
                S_SEND: begin
                    if (tx_count >= rx_length) begin
                        app_tx_data_valid <= 1'b0;
                        state <= S_IDLE;
                    end else begin
                        app_tx_data_valid <= 1'b1;
                        app_tx_data <= buffer[tx_count[PTR_WIDTH-1:0]];
                        tx_count <= tx_count + 1'b1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
