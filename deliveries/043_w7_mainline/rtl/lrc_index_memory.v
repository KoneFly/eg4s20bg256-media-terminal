`timescale 1ns/1ps
// 256x54宽字索引：六个9bit物理9K并行，最后两段可独立补写行长。
module lrc_index_memory(
    input wire clk,input wire [7:0] address_a,input wire [2:0] write_mask,input wire [53:0] data,
    output wire [53:0] q_a,input wire [7:0] address_b,output wire [53:0] q_b
);
`ifdef SIMULATION
    reg [53:0] memory[0:255];reg [53:0] a,b;
    always @(posedge clk)begin
        if(write_mask[0])memory[address_a][17:0]<=data[17:0];
        if(write_mask[1])memory[address_a][35:18]<=data[35:18];
        if(write_mask[2])memory[address_a][53:36]<=data[53:36];
        a<=memory[address_a];b<=memory[address_b];
    end
    assign q_a=a;assign q_b=b;
`else
    genvar i;
    for(i=0;i<6;i=i+1)begin:segment
        EG_PHY_BRAM #(
            .CEAMUX("1"),.CEBMUX("1"),.CSA0("1"),.CSA1("1"),.CSA2("1"),
            .CSB0("1"),.CSB1("1"),.CSB2("1"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),
            .MODE("DP8K"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.RESETMODE("SYNC"),
            .RSTAMUX("0"),.RSTBMUX("0"),.WEBMUX("0"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL")
        ) memory_ram(
            .dia(data[i*9+:9]),.addra({2'b0,address_a,3'b111}),.csa(3'b111),.cea(1'b1),.ocea(1'b0),
            .clka(clk),.wea(write_mask[i/2]),.rsta(1'b0),.doa(q_a[i*9+:9]),
            .dib(9'd0),.addrb({2'b0,address_b,3'b111}),.csb(3'b111),.ceb(1'b1),.oceb(1'b0),
            .clkb(clk),.web(1'b0),.rstb(1'b0),.dob(q_b[i*9+:9])
        );
    end
`endif
endmodule
