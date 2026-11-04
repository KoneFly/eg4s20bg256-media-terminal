`timescale 1ns/1ps
// 32bit字拆为2片16bit×256 DP9K，明确遵守9K真双口端宽限制。
module fdi_state_lane (
    input wire clk,input wire [7:0] rd_addr,output wire [31:0] rd_data,
    input wire wr_clk,we,input wire [7:0] wr_addr,input wire [31:0] wr_data
);
`ifdef VERILATOR
    reg [31:0] mem[0:255];
    reg [31:0] q;
    always @(posedge wr_clk)if(we)mem[wr_addr]<=wr_data;
    always @(posedge clk)q<=mem[rd_addr];
    assign rd_data=q;
`else
    genvar half;
    generate for(half=0;half<2;half=half+1)begin:word_half
        EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.DATA_WIDTH_B(16),.ADDR_WIDTH_A(8),.ADDR_WIDTH_B(8),
          .DATA_DEPTH_A(256),.DATA_DEPTH_B(256),.BYTE_ENABLE(0),.MODE("DP"),
          .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("9K")) mem(
          .dia(wr_data[half*16+:16]),.addra(wr_addr),.cea(1'b1),.ocea(1'b1),.clka(wr_clk),.wea(we),
          .rsta(1'b0),.bea(1'b1),.doa(),.dib(16'd0),.addrb(rd_addr),.ceb(1'b1),.oceb(1'b1),
          .clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b1),.dob(rd_data[half*16+:16]));
    end endgenerate
`endif
endmodule
