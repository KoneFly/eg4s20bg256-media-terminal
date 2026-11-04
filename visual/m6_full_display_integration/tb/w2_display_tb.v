`timescale 1ns/1ps
// 仅观测W2正式写/commit端口和状态存储正式读口，不访问更新器内部状态。
module w2_display_tb (
    input wire clk,rst,ctrl_clk,ctrl_rst_n,snapshot_done,label_ready,pixel_ready,pixel_valid,
    input wire [7:0] energy_data,input wire [31:0] pixel_data,
    output wire frame_request,pixel_take,video_de,video_vs,
    output wire [6:0] energy_addr,output wire [15:0] video_rgb,display_frames,
    output wire [7:0] error_code,
    output wire wr_en,wr_sel,commit,frame_done,frame_ready,
    output wire [7:0] wr_addr,trace_addr,misc_addr,output wire [1:0] wr_lane,
    output wire [31:0] wr_data,misc_data,output wire [127:0] trace_data,
    output wire rendered_valid,output wire [15:0] rendered,
    output wire [9:0] scan_h,scan_v,output wire [7:0] ctrl_error_sync
);
    v9_m6_scan u_scan(.clk(clk),.rst(rst),.snapshot_done(snapshot_done),.energy_data(energy_data),
      .frame_request(frame_request),.energy_addr(energy_addr),.video_de(video_de),.video_vs(video_vs),
      .video_rgb(video_rgb),.display_frames(display_frames),.ctrl_clk(ctrl_clk),.ctrl_rst_n(ctrl_rst_n),
      .label_ready(label_ready),.pixel_ready(pixel_ready),.pixel_data(pixel_data),.pixel_valid(pixel_valid),
      .pixel_take(pixel_take),.error_code(error_code));
    assign wr_en=u_scan.wr_en;assign wr_sel=u_scan.wr_sel;assign wr_addr=u_scan.wr_addr;
    assign wr_data=u_scan.wr_data;assign wr_lane=u_scan.wr_lane;assign commit=u_scan.state_commit;
    assign frame_done=u_scan.w2_done;assign frame_ready=u_scan.w2_ready;
    assign trace_addr=u_scan.trace_addr;assign misc_addr=u_scan.misc_addr;
    assign trace_data=u_scan.trace_data;assign misc_data=u_scan.misc_data;
    assign rendered_valid=u_scan.rendered_valid;assign rendered=u_scan.rendered;
    assign scan_h=u_scan.h;assign scan_v=u_scan.v;
    assign ctrl_error_sync=u_scan.ctrl_error_sync;
endmodule
