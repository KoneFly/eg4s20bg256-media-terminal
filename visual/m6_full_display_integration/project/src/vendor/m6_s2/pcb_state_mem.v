`timescale 1ns/1ps
// 真双口状态表；像素域自由运行同步读一拍，ctrl50整32bit写。
// 无复位清空路径；W2首批512+140写完成并commit后才开放S2。
module pcb_state_mem (
    input wire clk,input wire [7:0] st_trace_addr,
    output wire [127:0] st_trace_rdata,
    input wire [7:0] st_misc_addr,output wire [31:0] st_misc_rdata,
    input wire wr_clk,wr_en,wr_sel,input wire [7:0] wr_addr,
    input wire [31:0] wr_data,input wire [1:0] wr_lane
);
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1)begin:trace_lane
        fdi_state_lane u_mem(.clk(clk),.rd_addr({1'b0,st_trace_addr[6:0]}),
          .rd_data(st_trace_rdata[lane*32+:32]),.wr_clk(wr_clk),
          .we(wr_en && !wr_sel && wr_lane==lane[1:0]),
          .wr_addr({1'b0,wr_addr[6:0]}),.wr_data(wr_data));
    end endgenerate
    fdi_state_lane u_misc(.clk(clk),.rd_addr(st_misc_addr),.rd_data(st_misc_rdata),
      .wr_clk(wr_clk),.we(wr_en && wr_sel),.wr_addr(wr_addr),.wr_data(wr_data));
    wire unused_address_bits=^{st_trace_addr[7],wr_addr[7]};
endmodule
