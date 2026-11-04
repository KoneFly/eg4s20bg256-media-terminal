`timescale 1ns / 1ps
// 参考官方seg_scan/seg_decoder的低有效位选与abcdefg段码。
// 扩为8位，50MHz时钟使能扫描；16位数用16拍移位加3转换，避免组合除法。
// 左到右：P/d/r/E、页号、空格、5位十进制；每100ms取一次一致快照。
(* keep_hierarchy = "true" *)
module v7_decimal_display #(
    parameter integer SCAN_CYCLES=6250,
    parameter integer UPDATE_CYCLES=5000000
) (
    input wire clk, rst_n,
    input wire [15:0] value,
    input wire [1:0] mode,
    input wire [2:0] page,
    output reg [15:0] pins
);
    localparam [22:0] UPDATE_LAST=UPDATE_CYCLES[22:0]-23'd1;
    localparam [15:0] SCAN_LAST=SCAN_CYCLES[15:0]-16'd1;
    reg [22:0] update_count;
    reg [15:0] scan_count;
    reg [2:0] scan_index;
    reg busy, pending;
    reg [4:0] step;
    reg [15:0] binary_work;
    reg [19:0] bcd_work, bcd_pending, bcd_show;
    reg [1:0] mode_work, mode_pending, mode_show;
    reg [2:0] page_work, page_pending, page_show;
    reg [19:0] adjusted;
    integer j;
    always @(*) begin
        adjusted=bcd_work;
        for(j=0;j<5;j=j+1)
            if(bcd_work[j*4 +: 4]>=4'd5) adjusted[j*4 +: 4]=bcd_work[j*4 +: 4]+4'd3;
    end
    wire [35:0] shifted={adjusted,binary_work}<<1;
    function [7:0] decimal_glyph;
        input [3:0] digit;
        begin
            case(digit)
                0:decimal_glyph=8'hc0;1:decimal_glyph=8'hf9;2:decimal_glyph=8'ha4;
                3:decimal_glyph=8'hb0;4:decimal_glyph=8'h99;5:decimal_glyph=8'h92;
                6:decimal_glyph=8'h82;7:decimal_glyph=8'hf8;8:decimal_glyph=8'h80;
                9:decimal_glyph=8'h90;default:decimal_glyph=8'hff;
            endcase
        end
    endfunction
    reg [7:0] glyph;
    wire [7:0] select_n=~(8'b1<<scan_index);
    always @(*) begin
        if(scan_index<5) glyph=decimal_glyph(bcd_show[scan_index*4 +: 4]);
        else if(scan_index==5) glyph=8'hff;
        else if(scan_index==6) glyph=decimal_glyph({1'b0,page_show}) & 8'h7f;
        else begin
            case(mode_show)
                0:glyph=8'h8c; // P
                1:glyph=8'ha1; // d
                2:glyph=8'haf; // r
                default:glyph=8'h86; // E
            endcase
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            update_count<=0; scan_count<=0; scan_index<=0; pins<=16'hffff;
            busy<=0;pending<=0;step<=0;binary_work<=0;bcd_work<=0;bcd_pending<=0;bcd_show<=0;
            mode_work<=0;mode_pending<=0;mode_show<=0;page_work<=0;page_pending<=0;page_show<=0;
        end else begin
            if(update_count==UPDATE_LAST) update_count<=0;
            else update_count<=update_count+23'd1;
            if(!busy && (update_count==0 || mode!=mode_work || page!=page_work)) begin
                binary_work<=value;bcd_work<=0;step<=0;busy<=1;
                mode_work<=mode;page_work<=page;
            end else if(busy) begin
                binary_work<=shifted[15:0];bcd_work<=shifted[35:16];
                if(step==15) begin
                    busy<=0;pending<=1;bcd_pending<=shifted[35:16];
                    mode_pending<=mode_work;page_pending<=page_work;
                end else step<=step+5'd1;
            end
            // 换位先消隐一拍，整轮边界发布完成转换的快照。
            if(scan_count==0) pins<=16'hffff;
            else if(scan_count==1)
                pins<={select_n[0],select_n[1],select_n[2],select_n[3],
                       select_n[4],select_n[5],select_n[6],select_n[7],glyph};
            if(scan_count==SCAN_LAST) begin
                scan_count<=0;scan_index<=scan_index+3'd1;
                if(scan_index==7 && pending && !(busy && step==15)) begin
                    bcd_show<=bcd_pending;mode_show<=mode_pending;page_show<=page_pending;pending<=0;
                end
            end else scan_count<=scan_count+16'd1;
        end
    end
endmodule
