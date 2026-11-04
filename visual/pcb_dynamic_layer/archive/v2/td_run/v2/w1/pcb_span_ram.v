// 6144×24 行记录池：三个深度分片，每片两个 2048×16 RAM。
module pcb_span_ram (
    input wire clk,we,
    input wire [12:0] waddr,raddr,
    input wire [23:0] wdata,
    output wire [23:0] rdata
);
    wire [23:0] bank_q [0:2];
    reg [1:0] read_bank;
    always @(posedge clk)read_bank<=raddr[12:11];
    genvar n;
    generate for(n=0;n<3;n=n+1)begin:bank
        wire [15:0] q_hi;
        pcb_ram_2k16 low(clk,we&&waddr[12:11]==n[1:0],waddr[10:0],raddr[10:0],wdata[15:0],bank_q[n][15:0]);
        pcb_ram_2k16 high(clk,we&&waddr[12:11]==n[1:0],waddr[10:0],raddr[10:0],{8'd0,wdata[23:16]},q_hi);
        assign bank_q[n][23:16]=q_hi[7:0];
        wire [7:0] unused_q_hi=q_hi[15:8];
    end endgenerate
    assign rdata=read_bank<3 ? bank_q[read_bank] : 24'd0;
endmodule
