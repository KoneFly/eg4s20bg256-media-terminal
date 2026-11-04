`timescale 1ns / 1ps
// 来源：国一 Main/q3q4/import/udp_cam_ctrl.v 的发送控制块。
// 保留START/WAIT_FIFO/WAIT_UDP/WAIT_ACK/HEADER/DATA/DELAY状态及握手赋值。
// PCM替换图像载荷；原控制块实际输出33个头阶段字节及FRAME_SIZE-1个数据字节。
// 第33个字节映射到PCM载荷[32]，数据阶段映射[33..291]，总数仍为292。
(* keep_hierarchy = "true" *)
module v7_udp_cam_ctrl_pcm #(
    parameter [21:0] FIFO_WAIT_CYCLES=22'd2000,
    parameter [21:0] PACKET_GAP_CYCLES=22'd1500
) (
    input wire clk, input wire rst_n, input wire packet_ready,
    input wire udp_tx_ready, input wire app_tx_ack,
    input wire [7:0] payload_byte, output wire [8:0] payload_index,
    output wire [8:0] payload_prefetch_index,
    output reg packet_done,
    output reg app_tx_data_request, output reg app_tx_data_valid,
    output reg [7:0] app_tx_data, output reg [15:0] udp_data_length,
    output wire busy
);
    localparam [2:0] START_UDP=3'd0, WAIT_FIFO_RDY=3'd1, WAIT_UDP_DATA=3'd2,
                     WAIT_ACK=3'd3, SEND_UDP_HEADER=3'd4, SEND_UDP_DATA=3'd5, DELAY=3'd6;
    localparam [8:0] IMG_HEADER_LEN=9'd256;
    localparam [11:0] IMG_FRAMSIZE=12'd260;
    reg [2:0] STATE;
    reg [8:0] app_tx_header_cnt;
    reg [11:0] fifo_read_data_cnt;
    reg [21:0] delay_cnt;
    assign busy = (STATE == WAIT_ACK) || (STATE == SEND_UDP_HEADER)
               || (STATE == SEND_UDP_DATA) || (STATE == DELAY);
    assign payload_index = (STATE == SEND_UDP_HEADER) ? {3'd0, app_tx_header_cnt[8:3]}
                         : ((STATE == SEND_UDP_DATA) && (fifo_read_data_cnt < 12'd259))
                           ? fifo_read_data_cnt[8:0] + 9'd33 : 9'd0;
    // 同步RAM提前一拍读取下一字节；不改变下方国一发送控制块的赋值时序。
    assign payload_prefetch_index = ((STATE == WAIT_ACK) && app_tx_ack) ? 9'd1
                                  : (STATE == SEND_UDP_HEADER) ? {3'd0, app_tx_header_cnt[8:3]} + 9'd1
                                  : ((STATE == SEND_UDP_DATA) && (fifo_read_data_cnt < 12'd258))
                                    ? fifo_read_data_cnt[8:0] + 9'd34 : 9'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            STATE <= START_UDP;
            app_tx_data_request <= 0; app_tx_data_valid <= 0; app_tx_data <= 0;
            udp_data_length <= 16'd292;
            app_tx_header_cnt <= 0; fifo_read_data_cnt <= 0; delay_cnt <= 0; packet_done <= 0;
        end else begin
            packet_done <= 0;
            case (STATE)
                START_UDP: begin
                    app_tx_data_request <= 0; app_tx_data_valid <= 0;
                    fifo_read_data_cnt <= 0; delay_cnt <= 0;
                    STATE <= WAIT_FIFO_RDY;
                end
                WAIT_FIFO_RDY: begin
                    // PCM整帧缓存替代SDRAM读取就绪；握手前不读尚未装齐的包。
                    if (!packet_ready) delay_cnt <= 0;
                    else if (delay_cnt >= FIFO_WAIT_CYCLES) begin
                        delay_cnt <= 0; STATE <= WAIT_UDP_DATA;
                    end else begin
                        delay_cnt <= delay_cnt + 22'd1; STATE <= WAIT_FIFO_RDY;
                    end
                end
                WAIT_UDP_DATA: begin
                    if (udp_tx_ready) begin app_tx_data_request <= 1; STATE <= WAIT_ACK; end
                    else begin app_tx_data_request <= 0; STATE <= WAIT_UDP_DATA; end
                end
                WAIT_ACK: begin
                    if (app_tx_ack) begin
                        app_tx_data_request <= 0; app_tx_header_cnt <= 9'd8;
                        app_tx_data_valid <= 1; app_tx_data <= payload_byte;
                        STATE <= SEND_UDP_HEADER;
                    end else begin app_tx_data_request <= 1; STATE <= WAIT_ACK; end
                end
                SEND_UDP_HEADER: begin
                    if (app_tx_header_cnt >= IMG_HEADER_LEN) begin
                        STATE <= SEND_UDP_DATA;
                        app_tx_data_valid <= 1; app_tx_data <= payload_byte;
                        app_tx_header_cnt <= 0; fifo_read_data_cnt <= 0;
                    end else begin
                        STATE <= SEND_UDP_HEADER;
                        app_tx_data_valid <= 1; app_tx_data <= payload_byte;
                        app_tx_header_cnt <= app_tx_header_cnt + 9'd8;
                    end
                end
                SEND_UDP_DATA: begin
                    app_tx_data <= payload_byte;
                    if (fifo_read_data_cnt >= (IMG_FRAMSIZE - 12'd1)) begin
                        fifo_read_data_cnt <= 0; app_tx_data_valid <= 0;
                        packet_done <= 1; STATE <= DELAY;
                    end else begin
                        fifo_read_data_cnt <= fifo_read_data_cnt + 12'd1;
                        app_tx_data_valid <= 1; STATE <= SEND_UDP_DATA;
                    end
                end
                DELAY: begin
                    if (delay_cnt >= PACKET_GAP_CYCLES) begin
                        delay_cnt <= 0;
                        // 一个PCM包对应一个完整对象，等价于原IMG_FRAMTOTAL=1分支。
                        STATE <= START_UDP;
                    end else begin delay_cnt <= delay_cnt + 22'd1; STATE <= DELAY; end
                end
                default: STATE <= START_UDP;
            endcase
        end
    end
endmodule
