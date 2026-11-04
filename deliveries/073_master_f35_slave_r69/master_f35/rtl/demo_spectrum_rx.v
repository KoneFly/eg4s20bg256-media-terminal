`timescale 1ns/1ps
// 同版本多谱回程：应用组校验与只读命令资格输出解耦，串行格式保持038不变。
module demo_spectrum_rx(
    input wire clk,rst_n,serial_data,bank_free,bank_reset,
    output wire write_valid,
    output wire [8:0] write_address,
    output wire [7:0] write_data,
    output wire publish,
    output wire [1:0] publish_paths,
    output wire [31:0] publish_epoch,publish_end,
    output wire [15:0] accepted,rejected,dropped,
    output reg [15:0] metadata_rejections,
    output wire locked,
    output wire [7:0] transport_errors,
    output wire [15:0] transport_lost
);
    `include "link062_crc.vh"
    wire [95:0] energy,decoded;
    wire valid,strobe,cmd_valid;
    wire [1:0] kind;
    wire [2:0] version;
    wire [7:0] param;
    wire [15:0] id;
    wire [3:0] reject_reason;
    reg [15:0] rejected_previous;
    demo_interboard_rx u_transport(
        .clk(clk),.rst_n(rst_n),.link_clk(1'b0),.link_sync(1'b0),.link_data(serial_data),
        .energy(energy),.energy_valid(valid),.asset_id(kind),.effect_mode(version),.param(param),
        .frame_ref_out(strobe),.frame_id_out(id),.link_locked(locked),.link_error(transport_errors),
        .frame_lost_cnt(transport_lost),.cmd_valid_out(cmd_valid)
    );
    assign decoded=seed_transform(energy,param[2:0]);
    multi_spectrum_group_rx_shiftadd_r03 u_group(
        .clk(clk),.rst_n(rst_n),.link_locked(locked),.packet_valid(valid),.frame_strobe(strobe),
        .cmd_valid(cmd_valid),.asset_id(kind),.version(version),.param(param),.packet_id(id),.decoded_payload(decoded),
        .bank_free(bank_free),.bank_reset(bank_reset),.write_valid(write_valid),.write_address(write_address),.write_data(write_data),
        .publish(publish),.publish_path_count(publish_paths),.publish_epoch(publish_epoch),.publish_end_sample(publish_end),
        .accepted_groups(accepted),.rejected_groups(rejected),.dropped_groups(dropped),.reject_reason(reject_reason)
    );
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin rejected_previous<=0;metadata_rejections<=0;end
        else begin
            rejected_previous<=rejected;
            if(rejected!=rejected_previous&&reject_reason==4'd5&&metadata_rejections!=16'hffff)
                metadata_rejections<=metadata_rejections+16'd1;
        end
    end
endmodule
