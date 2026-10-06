`timescale 1ns/1ps
// 目录事件稳定至少20拍，8拍串写四槽元数据；后续复用空闲区记录访问过的簇。
module lrc_slot_store(
    input wire clk,input wire rst,input wire invalidate,
    input wire entry_valid,input wire [1:0] entry_slot,input wire [31:0] entry_cluster,input wire [31:0] entry_size,
    output reg [3:0] valid,output reg busy,
    input wire [6:0] read_address_a,output wire [7:0] read_data_a,
    input wire [6:0] read_address_b,output wire [7:0] read_data_b,
    input wire visited_we,input wire [6:0] visited_address,input wire [7:0] visited_data
);
    reg [1:0] slot;
    reg [2:0] byte_index;
    reg [7:0] entry_data;
    wire [6:0] address_a=busy?{2'd0,slot,byte_index}:visited_we?visited_address:read_address_a;
    wire [7:0] data_a=busy?entry_data:visited_data;
    wire write_enable=!invalidate && (busy || visited_we);
    always @*case(byte_index)
        0:entry_data=entry_cluster[7:0];1:entry_data=entry_cluster[15:8];
        2:entry_data=entry_cluster[23:16];3:entry_data=entry_cluster[31:24];
        4:entry_data=entry_size[7:0];5:entry_data=entry_size[15:8];
        6:entry_data=entry_size[23:16];default:entry_data=entry_size[31:24];
    endcase
    always @(posedge clk or posedge rst)begin
        if(rst)begin valid<=0;busy<=0;slot<=0;byte_index<=0;end
        else if(invalidate)begin valid<=0;busy<=0;byte_index<=0;end
        else if(busy)begin
            if(byte_index==7)begin busy<=0;valid[slot]<=1;end else byte_index<=byte_index+3'd1;
        end else if(entry_valid)begin slot<=entry_slot;byte_index<=0;busy<=1;end
    end
`ifdef SIMULATION
    reg [7:0] memory[0:127];reg [7:0] qa,qb;
    always @(posedge clk)begin
        if(write_enable)memory[address_a]<=data_a;
        qa<=memory[address_a];qb<=memory[read_address_b];
    end
    assign read_data_a=qa;assign read_data_b=qb;
`else
    wire [8:0] da,db;
    EG_PHY_BRAM #(
        .CEAMUX("1"),.CEBMUX("1"),.CSA0("1"),.CSA1("1"),.CSA2("1"),
        .CSB0("1"),.CSB1("1"),.CSB2("1"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),
        .MODE("DP8K"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.RESETMODE("SYNC"),
        .RSTAMUX("0"),.RSTBMUX("0"),.WEBMUX("0"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL")
    ) memory_ram(
        .dia({1'b0,data_a}),.addra({3'd0,address_a,3'b111}),.csa(3'b111),.cea(1'b1),.ocea(1'b0),
        .clka(clk),.wea(write_enable),.rsta(1'b0),.doa(da),
        .dib(9'd0),.addrb({3'd0,read_address_b,3'b111}),.csb(3'b111),.ceb(1'b1),.oceb(1'b0),
        .clkb(clk),.web(1'b0),.rstb(1'b0),.dob(db)
    );
    assign read_data_a=da[7:0];assign read_data_b=db[7:0];
`endif
endmodule
