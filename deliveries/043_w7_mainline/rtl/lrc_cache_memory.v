`timescale 1ns/1ps
// 正文采用CTRL写/pixel读；索引采用物理双口9K。写入须在隐藏确认后开始。
module lrc_cache_memory #(
    parameter TEXT=1'b1,
    parameter integer WIDTH=TEXT?13:11
)(
    input wire ctrl_clk,input wire [WIDTH-1:0] ctrl_address,
    input wire ctrl_we,input wire [7:0] ctrl_data,output wire [7:0] ctrl_q,
    input wire pixel_clk,input wire [WIDTH-1:0] pixel_address,output wire [7:0] pixel_q
);
    generate if(TEXT)begin: text_cache
        (* ram_style="bram_32k" *) reg [7:0] memory[0:8191];
        reg [7:0] q;
        always @(posedge ctrl_clk)if(ctrl_we)memory[ctrl_address]<=ctrl_data;
        always @(posedge pixel_clk)q<=memory[pixel_address];
        assign ctrl_q=8'd0;
        assign pixel_q=q;
    end else begin: index_cache
`ifdef SIMULATION
        reg [7:0] memory[0:2047];reg [7:0] qa,qb;
        always @(posedge ctrl_clk)begin
            if(ctrl_we)memory[ctrl_address]<=ctrl_data;
            qa<=memory[ctrl_address];
        end
        always @(posedge pixel_clk)qb<=memory[pixel_address];
        assign ctrl_q=qa;assign pixel_q=qb;
`else
        wire [8:0] da[0:1],db[0:1];reg bank_a,bank_b;
        always @(posedge ctrl_clk)bank_a<=ctrl_address[10];
        always @(posedge pixel_clk)bank_b<=pixel_address[10];
        genvar n;
        for(n=0;n<2;n=n+1)begin:bank
            EG_PHY_BRAM #(
                .CEAMUX("1"),.CEBMUX("1"),.CSA0("1"),.CSA1("1"),.CSA2("1"),
                .CSB0("1"),.CSB1("1"),.CSB2("1"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),
                .MODE("DP8K"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.RESETMODE("SYNC"),
                .RSTAMUX("0"),.RSTBMUX("0"),.WEBMUX("0"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL")
            ) ram(
                .dia({1'b0,ctrl_data}),.addra({ctrl_address[9:0],3'b111}),.csa(3'b111),
                .cea(1'b1),.ocea(1'b0),.clka(ctrl_clk),.wea(ctrl_we&&(ctrl_address[10]==(n==1))),.rsta(1'b0),.doa(da[n]),
                .dib(9'd0),.addrb({pixel_address[9:0],3'b111}),.csb(3'b111),
                .ceb(1'b1),.oceb(1'b0),.clkb(pixel_clk),.web(1'b0),.rstb(1'b0),.dob(db[n])
            );
        end
        assign ctrl_q=bank_a?da[1][7:0]:da[0][7:0];
        assign pixel_q=bank_b?db[1][7:0]:db[0][7:0];
`endif
    end endgenerate
endmodule
