// 端口行为：同步读一拍；完整 16bit 写入。TD 使用器件公开 RAM 原语接口。
module pcb_ram_2k16 (
    input wire clk, we,
    input wire [10:0] waddr,raddr,
    input wire [15:0] wdata,
    output wire [15:0] rdata
);
`ifdef VERILATOR
    reg [15:0] mem [0:2047];
    reg [15:0] q;
    always @(posedge clk)begin q<=mem[raddr];if(we)mem[waddr]<=wdata;end
    assign rdata=q;
`else
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16),.DATA_WIDTH_B(16),.ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
        .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),.BYTE_ENABLE(0),.MODE("DP"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K")
    ) mem (
        .dia(wdata),.addra(waddr),.cea(1'b1),.ocea(1'b1),.clka(clk),.wea(we),.rsta(1'b0),.bea(1'b1),.doa(),
        .dib(16'd0),.addrb(raddr),.ceb(1'b1),.oceb(1'b1),.clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b1),.dob(rdata)
    );
`endif
endmodule
