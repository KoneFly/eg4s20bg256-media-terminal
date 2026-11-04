`timescale 1ns/1ps
// 038 解码后的应用层多谱组接收器。组数据先写入调用方的非活动bank，尾包
// 校验成功后才发出publish；本模块不修改038传输层，也不拥有显示bank。
module multi_spectrum_group_rx_shiftadd_r03(
    input wire clk,
    input wire rst_n,
    input wire link_locked,
    input wire packet_valid,
    input wire cmd_valid,
    input wire frame_strobe,
    input wire [1:0] asset_id,
    input wire [2:0] version,
    input wire [7:0] param,
    input wire [15:0] packet_id,
    input wire [95:0] decoded_payload,
    input wire bank_free,
    input wire bank_reset,
    output reg write_valid,
    output reg [8:0] write_address,
    output reg [7:0] write_data,
    output reg publish,
    output reg [1:0] publish_path_count,
    output reg [31:0] publish_epoch,
    output reg [31:0] publish_end_sample,
    output reg [15:0] accepted_groups,
    output reg [15:0] rejected_groups,
    output reg [15:0] dropped_groups,
    output reg [3:0] reject_reason
);
    `include "multi_spectrum_crc_r02.vh"
    // 低三位属于传输层白化种子，应用层只消费高五位标签。
    wire unused_reserved_param = ^param[2:0];

    localparam [3:0] REJECT_NONE=4'd0;
    localparam [3:0] REJECT_FRAME=4'd1;
    localparam [3:0] REJECT_FRAGMENT=4'd2;
    localparam [3:0] REJECT_SEQUENCE=4'd3;
    localparam [3:0] REJECT_LENGTH=4'd4;
    localparam [3:0] REJECT_META=4'd5;
    localparam [3:0] REJECT_CRC=4'd6;
    localparam [3:0] REJECT_STALE=4'd7;
    localparam [3:0] REJECT_LOCK=4'd8;
    localparam [3:0] REJECT_OVERLAP=4'd9;
    localparam [3:0] REJECT_BANK_BUSY=4'd10;
    localparam [3:0] REJECT_CMD_VALID=4'd11;

    reg active, bad_group, discard_group, have_packet_id;
    reg history_valid, previous_locked;
    reg [15:0] expected_packet_id;
    reg [5:0] next_fragment;
    reg [8:0] byte_count;
    reg [3:0] bytes_left, byte_index;
    reg [95:0] pending_payload;
    reg [15:0] crc_running, crc_n1_checkpoint, crc_n2_checkpoint;
    wire [7:0] current_byte = pending_payload[byte_index*8 +: 8];
    wire [15:0] crc_next = crc16_byte(crc_running,current_byte);
    reg [31:0] old_epoch, old_end_sample;

    wire sequence_ok = !have_packet_id || packet_id == expected_packet_id;
    wire [5:0] fragment_tag = {1'b0,param[7:3]};
    wire [7:0] tail_tag = {3'd0,param[7:3]};
    wire [7:0] tail_path_count = decoded_payload[95:88];
    wire [7:0] tail_channel_count = decoded_payload[87:80];
    wire [15:0] tail_crc = decoded_payload[79:64];
    wire [31:0] tail_epoch = decoded_payload[31:0];
    wire [31:0] tail_end_sample = decoded_payload[63:32];
`ifdef MUTANT_ACCEPT_OLD_META
    wire [7:0] accepted_path_count = tail_path_count == 0 ? 8'd1 : tail_path_count;
`else
    wire [7:0] accepted_path_count = tail_path_count;
`endif
    // 8位移位加法精确保留accepted_path_count*11的模256语义。
    wire [7:0] path_count_times_11 =
        {accepted_path_count[4:0],3'b000} +
        {accepted_path_count[6:0],1'b0} + accepted_path_count;
    wire [7:0] expected_fragments = accepted_path_count == 8'd3 ? 8'd32 : path_count_times_11;
    // 9位移位加法与原next_fragment*9'd12保持相同模512语义。
    wire [8:0] next_fragment_times_12 =
        {next_fragment,3'b000} + {1'b0,next_fragment,2'b00};
`ifdef MUTANT_IGNORE_CRC
    wire crc_match = 1'b1;
`else
    wire crc_match = (accepted_path_count == 1 && tail_crc == crc_n1_checkpoint) ||
                     (accepted_path_count == 2 && tail_crc == crc_n2_checkpoint) ||
                     (accepted_path_count == 3 && tail_crc == crc_running);
`endif
    wire forward = !history_valid || tail_epoch != old_epoch ||
        ((tail_end_sample != old_end_sample) &&
         ((tail_end_sample[31] ^ old_end_sample[31]) ==
          (tail_end_sample[30:0] < old_end_sample[30:0])));

    always @(posedge clk) begin
        if (!rst_n) begin
            write_valid <= 1'b0;
            write_address <= 9'd0;
            write_data <= 8'd0;
            publish <= 1'b0;
            publish_path_count <= 2'd0;
            publish_epoch <= 32'd0;
            publish_end_sample <= 32'd0;
            accepted_groups <= 16'd0;
            rejected_groups <= 16'd0;
            dropped_groups <= 16'd0;
            reject_reason <= REJECT_NONE;
            active <= 1'b0;
            bad_group <= 1'b0;
            discard_group <= 1'b0;
            have_packet_id <= 1'b0;
            history_valid <= 1'b0;
            previous_locked <= 1'b0;
            expected_packet_id <= 16'd0;
            next_fragment <= 6'd0;
            byte_count <= 9'd0;
            bytes_left <= 4'd0;
            byte_index <= 4'd0;
            pending_payload <= 96'd0;
            crc_running <= 16'hffff;
            crc_n1_checkpoint <= 16'hffff;
            crc_n2_checkpoint <= 16'hffff;
            old_epoch <= 32'd0;
            old_end_sample <= 32'd0;
        end else begin
            publish <= 1'b0;
            write_valid <= 1'b0;
            previous_locked <= link_locked;

            if (bytes_left != 0) begin
                if (active && !bad_group && !discard_group && byte_count < 9'd384) begin
                    write_valid <= 1'b1;
                    write_address <= byte_count;
                    write_data <= current_byte;
                end
                if (byte_count < 9'd384) begin
                    crc_running <= crc_next;
                    if (byte_count == 9'd127) crc_n1_checkpoint <= crc_next;
                    if (byte_count == 9'd255) crc_n2_checkpoint <= crc_next;
                end
                byte_count <= byte_count + 9'd1;
                byte_index <= byte_index + 4'd1;
                bytes_left <= bytes_left - 4'd1;
            end

            if (bank_reset || (previous_locked && !link_locked)) begin
                active <= 1'b0;
                bad_group <= 1'b0;
                discard_group <= 1'b0;
                have_packet_id <= 1'b0;
                history_valid <= 1'b0;
                bytes_left <= 4'd0;
                write_valid <= 1'b0;
                reject_reason <= bank_reset ? REJECT_NONE : REJECT_LOCK;
            end else if (packet_valid) begin
                have_packet_id <= 1'b1;
                expected_packet_id <= packet_id + 16'd1;

                if (!cmd_valid && (asset_id == 2'd2 || asset_id == 2'd3)) begin
                    bad_group <= 1'b1;
                    active <= 1'b0;
                    reject_reason <= REJECT_CMD_VALID;
                end else if (version != 3'd0 || !frame_strobe || bytes_left != 0 || !link_locked) begin
                    bad_group <= 1'b1;
                    active <= 1'b0;
                    reject_reason <= (bytes_left != 0) ? REJECT_OVERLAP :
                                     (!link_locked ? REJECT_LOCK : REJECT_FRAME);
                end else if (!sequence_ok) begin
                    bad_group <= 1'b1;
                    active <= 1'b0;
                    reject_reason <= REJECT_SEQUENCE;
                end else if (asset_id == 2'd2) begin
                    if (fragment_tag == 0) begin
                        active <= 1'b1;
                        bad_group <= 1'b0;
                        discard_group <= !bank_free;
                        reject_reason <= REJECT_NONE;
                        next_fragment <= 6'd1;
                        byte_count <= 9'd0;
                        crc_running <= 16'hffff;
                        crc_n1_checkpoint <= 16'hffff;
                        crc_n2_checkpoint <= 16'hffff;
                        byte_index <= 4'd0;
                        bytes_left <= 4'd12;
                        pending_payload <= decoded_payload;
                        if (!bank_free) dropped_groups <= dropped_groups + 16'd1;
                    end else if (active && !bad_group && fragment_tag == next_fragment &&
                                 next_fragment < 6'd32 && byte_count < 9'd384) begin
                        next_fragment <= next_fragment + 6'd1;
                        byte_index <= 4'd0;
                        bytes_left <= 4'd12;
                        pending_payload <= decoded_payload;
                    end else begin
                        bad_group <= 1'b1;
                        active <= 1'b0;
                        if (!bad_group) reject_reason <= REJECT_FRAGMENT;
                    end
                end else if (asset_id == 2'd3) begin
                    if (tail_tag == 1 && active && !bad_group && sequence_ok && bytes_left == 0 &&
                        tail_channel_count == 8'd128 && accepted_path_count >= 1 && accepted_path_count <= 3 &&
                        byte_count == next_fragment_times_12 &&
                        {2'd0,next_fragment} == expected_fragments &&
                        crc_match &&
                        forward && !discard_group) begin
                        publish <= 1'b1;
                        publish_path_count <= accepted_path_count[1:0];
                        publish_epoch <= tail_epoch;
                        publish_end_sample <= tail_end_sample;
                        old_epoch <= tail_epoch;
                        old_end_sample <= tail_end_sample;
                        history_valid <= 1'b1;
                        accepted_groups <= accepted_groups + 16'd1;
                        reject_reason <= REJECT_NONE;
                    end else begin
                        rejected_groups <= rejected_groups + 16'd1;
                        if (bad_group && reject_reason != REJECT_NONE) reject_reason <= reject_reason;
                        else if (tail_tag != 1) reject_reason <= REJECT_FRAGMENT;
                        else if (discard_group) reject_reason <= REJECT_BANK_BUSY;
                        else if (tail_channel_count != 8'd128 || accepted_path_count < 1 || accepted_path_count > 3)
                            reject_reason <= REJECT_META;
                        else if (byte_count != next_fragment_times_12 ||
                                 {2'd0,next_fragment} != expected_fragments)
                            reject_reason <= REJECT_LENGTH;
                        else if (!crc_match)
                            reject_reason <= REJECT_CRC;
                        else if (!forward) reject_reason <= REJECT_STALE;
                        else reject_reason <= REJECT_FRAME;
                    end
                    active <= 1'b0;
                    bad_group <= 1'b0;
                    discard_group <= 1'b0;
                    bytes_left <= 4'd0;
                end else begin
                    bad_group <= 1'b1;
                    active <= 1'b0;
                    reject_reason <= REJECT_FRAME;
                end
            end
        end
    end
endmodule
