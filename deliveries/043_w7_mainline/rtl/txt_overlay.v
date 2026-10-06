`timescale 1ns/1ps
// 四行紧凑仪表盘与底部说明条：非活动银行写入、消隐窗一次提交、字符预取保持原像素握手。
module txt_overlay #(
    parameter [9:0] VSTART = 10'd35
)(
    input wire clk,
    input wire rst,
    input wire vs,
    input wire hs,
    input wire de,
    input wire advance,
    input wire write_enable,
    input wire [8:0] write_address,
    input wire [7:0] write_character,
    input wire ready_toggle,
    input wire ready_bank,
    input wire ready_help_adjust,
    input wire lyric_valid,input wire [6:0] lyric_length,input wire [10:0] lyric_scroll,input wire [7:0] lyric_character,
    output wire [6:0] lyric_read_column,
    output reg acknowledge_toggle,
    output wire mask,
    output wire text
);
    wire [7:0] read_character;
    wire [8:0] read_address;
`ifdef SIMULATION
    // 行为模型与同步单拍读契约一致，仅仿真使用，不参与硬件实现。
    reg [7:0] characters [0:511];
    reg [7:0] read_character_sim;
    always @(posedge clk) begin
        if(write_enable) characters[write_address] <= write_character;
        read_character_sim <= characters[read_address];
    end
    assign read_character=read_character_sim;
`else
    // 文本RAM不依赖上电初值；非活动银行完整写入后才发布可见内容。
    // 9bit物理地址采用官方门级映射的低三位111，无额外输出寄存级。
    wire [8:0] ram_read_data;
    EG_PHY_BRAM #(
        .CEAMUX("1"),
        .CEBMUX("1"),
        .CSA0("1"),
        .CSA1("1"),
        .CSA2("1"),
        .CSB0("1"),
        .CSB1("1"),
        .CSB2("1"),
        .DATA_WIDTH_A("9"),
        .DATA_WIDTH_B("9"),
        .MODE("DP8K"),
        .REGMODE_A("NOREG"),
        .REGMODE_B("NOREG"),
        .RESETMODE("SYNC"),
        .RSTAMUX("0"),
        .RSTBMUX("0"),
        .WEBMUX("0"),
        .WRITEMODE_A("NORMAL"),
        .WRITEMODE_B("NORMAL"),
        .INITP_00(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INITP_01(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INITP_02(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INITP_03(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_00(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_01(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_02(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_03(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_04(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_05(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_06(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_07(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_08(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_09(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_0A(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_0B(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_0C(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_0D(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_0E(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_0F(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_10(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_11(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_12(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_13(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_14(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_15(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_16(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_17(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_18(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_19(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_1A(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_1B(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_1C(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_1D(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_1E(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_1F(256'h0000000000000000000000000000000000000000000000000000000000000000)
    ) u_text_ram (
        .dia({1'b0,write_character}),.addra({1'b0,write_address,3'b111}),
        .csa(3'b111),.cea(1'b1),.ocea(1'b0),.clka(clk),.wea(write_enable),.rsta(1'b0),
        .dib(9'd0),.addrb({1'b0,read_address,3'b111}),.csb(3'b111),
        .ceb(1'b1),.oceb(1'b0),.clkb(clk),.web(1'b0),.rstb(1'b0),.doa(),.dob(ram_read_data)
    );
    assign read_character=ram_read_data[7:0];
`endif

    reg [9:0] line_count, x_count;
    reg vs_d, hs_d;
    wire vs_fall = vs_d && !vs;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            line_count <= 10'd0;
            x_count <= 10'd0;
            vs_d <= 1'b1;
            hs_d <= 1'b1;
        end else begin
            vs_d <= vs;
            hs_d <= hs;
            if (vs_fall) line_count <= 10'd0;
            else if (hs_d && !hs) line_count <= line_count + 10'd1;
            if (!de) x_count <= 10'd0;
            else if (advance && x_count != 10'd639) x_count <= x_count + 10'd1;
        end
    end

    reg active_bank, content_valid, committed_this_blank;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            active_bank <= 1'b0;
            content_valid <= 1'b0;
            committed_this_blank <= 1'b0;
            acknowledge_toggle <= 1'b0;
        end else begin
            if (vs_fall) committed_this_blank <= 1'b0;
            if (line_count < VSTART && !committed_this_blank &&
                ready_toggle != acknowledge_toggle) begin
                active_bank <= ready_bank;
                content_valid <= 1'b1;
                acknowledge_toggle <= ready_toggle;
                committed_this_blank <= 1'b1;
            end
        end
    end

    wire lyric_row=line_count>=VSTART+10'd432 && line_count<VSTART+10'd444;
    wire [9:0] lyric_line=line_count-VSTART-10'd432;
    wire help_row = line_count >= VSTART + 10'd456;
    wire [9:0] relative_line = line_count - VSTART - 10'd8;
    wire [1:0] top_row = relative_line[5:4];
    wire [9:0] help_line = line_count - VSTART - 10'd456;
    wire [3:0] row_phase = lyric_row?lyric_line[3:0]:help_row ? help_line[3:0] : relative_line[3:0];
    wire top_box = line_count >= VSTART + 10'd8 && relative_line < 10'd64 && row_phase < 4'd12;
    wire help_box = help_row && help_line < 10'd12;
    wire bank_commit = line_count < VSTART && !committed_this_blank && ready_toggle != acknowledge_toggle;
    wire [10:0] scroll_offset;
    help_marquee u_marquee(.clk(clk),.rst(rst),.frame_tick(vs_fall),.content_valid(content_valid),
        .bank_commit(bank_commit),.ready_adjust(ready_help_adjust),.offset(scroll_offset));
    wire [9:0] top_relative_x = x_count - 10'd12;
    wire [11:0] help_virtual_x = {2'd0,((x_count < 10'd8)?10'd8:x_count)} + {1'b0,scroll_offset};
    wire [11:0] help_relative_x = help_virtual_x - 12'd636;
    wire [11:0] lyric_virtual_x={2'd0,((x_count<10'd8)?10'd8:x_count)}+{1'b0,(lyric_length>7'd77 ? lyric_scroll:11'd624)};
    wire [11:0] active_virtual_x=lyric_row?lyric_virtual_x:help_virtual_x;
    wire [11:0] relative_x = (lyric_row || help_row)?active_virtual_x-12'd636:{2'd0,top_relative_x};
    reg [6:0] line_length;
    wire help_viewport = x_count >= 10'd8 && x_count < 10'd632;
    wire [6:0] active_length=lyric_row?lyric_length:line_length;
    wire in_character_x = (lyric_row || help_row)?(help_viewport && relative_x < {2'd0,active_length,3'd0}) :
                                  (x_count >= 10'd12 && x_count < 10'd524);
    wire [6:0] column = (lyric_row || help_row)?((active_virtual_x<12'd636)?7'd0:relative_x[9:3]) :
                        (in_character_x?{1'b0,relative_x[8:3]}:7'd0);
    wire [6:0] last_column = (lyric_row || help_row)?7'd127:7'd31;
    // 左边缘从字符尾像素开始时，借视口外最后一像素预取下一字；背压保持当前字。
    wire help_left_prefetch = (lyric_row || help_row) && x_count == 10'd7 && advance &&
                              relative_x < {2'd0,active_length,3'd0};
    wire prefetch = (in_character_x || help_left_prefetch) && relative_x[2:0] >= 3'd6 && column != last_column;
    wire [6:0] read_column = x_count < 10'd4 ? last_column : column + {6'd0,prefetch};
    wire [7:0] row_address = help_row ? {1'b1,read_column} : {1'b0,top_row,read_column[4:0]};
    assign read_address = {active_bank,row_address};
    assign lyric_read_column=read_column;
    wire [7:0] character_in=lyric_row?lyric_character:read_character;
    reg [7:0] current_character;
    always @(posedge clk or posedge rst) begin
        if(rst) begin line_length<=7'd0;current_character<=8'h20;end
        else begin
            if(!de || x_count < 10'd4) line_length<=read_character[6:0];
            if((x_count >= 10'd4 && x_count < ((lyric_row || help_row)?10'd8:10'd12)) ||
               ((lyric_row || help_row) && active_virtual_x < 12'd636)) current_character<=character_in;
            else if(advance && in_character_x && relative_x[2:0]==3'd7) current_character<=character_in;
        end
    end
    wire [2:0] glyph_y = row_phase[2:0] - 3'd2;
    wire [7:0] glyph_bits;
    text_glyph_rom u_glyphs(.clk(clk),.code(current_character),.row(glyph_y),.bits(glyph_bits));
    wire [10:0] right_edge = 11'd16 + {1'b0,line_length,3'd0};
    wire top_mask = x_count >= 10'd8 && {1'b0,x_count} < right_edge && top_box;
    wire help_mask = help_box && help_viewport && help_virtual_x >= 12'd632 &&
                     help_virtual_x < 12'd640 + {2'd0,line_length,3'd0};
    wire lyric_mask=lyric_valid && lyric_row && help_viewport && lyric_virtual_x>=12'd632 &&
                    lyric_virtual_x<12'd640+{2'd0,lyric_length,3'd0};
    assign mask = de && content_valid && (top_mask || help_mask || lyric_mask);
    assign text = mask && in_character_x && row_phase >= 4'd2 && row_phase <= 4'd9 &&
                  column < active_length && glyph_bits[3'd7-relative_x[2:0]];
endmodule
