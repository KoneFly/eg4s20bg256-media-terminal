`timescale 1ns/1ps
// Small fixed-frequency axis for the existing 128-band logarithmic spectrum rows.
module spectrum_frequency_axis(
    input wire de,
    input wire top_display_valid,
    input wire bottom_display_valid,
    input wire pair_post_active,
    input wire single_active,
    input wire [9:0] pixel_x,
    input wire [9:0] absolute_line,
    output wire axis_mask,
    output wire axis_text
);
    // Row-valid signals gate each row and its axis labels independently.
    wire x_in_panel = pixel_x >= 10'd8 && pixel_x <= 10'd631;
    wire x_in_plot = pixel_x >= 10'd64 && pixel_x <= 10'd575;
    wire top_panel_line = absolute_line >= 10'd259 && absolute_line <= 10'd275;
    wire bottom_panel_line = absolute_line >= 10'd451 && absolute_line <= 10'd467;
    wire top_panel = top_display_valid && top_panel_line;
    wire bottom_panel = bottom_display_valid && bottom_panel_line;
    assign axis_mask = de && x_in_panel && (top_panel || bottom_panel);

    function [34:0] glyph_bitmap;
        input [7:0] code;
        begin
            case (code)
                8'h30: glyph_bitmap={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                8'h31: glyph_bitmap={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                8'h32: glyph_bitmap={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                8'h33: glyph_bitmap={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                8'h34: glyph_bitmap={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                8'h35: glyph_bitmap={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                8'h36: glyph_bitmap={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                8'h37: glyph_bitmap={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                8'h38: glyph_bitmap={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                8'h39: glyph_bitmap={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
                8'h41: glyph_bitmap={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                8'h48: glyph_bitmap={5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                8'h4c: glyph_bitmap={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                8'h4f: glyph_bitmap={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                8'h50: glyph_bitmap={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                8'h52: glyph_bitmap={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                8'h53: glyph_bitmap={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                8'h54: glyph_bitmap={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                8'h57: glyph_bitmap={5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                8'h59: glyph_bitmap={5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                8'h6b: glyph_bitmap={5'b10000,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
                8'h7a: glyph_bitmap={5'b00000,5'b00000,5'b11111,5'b00010,5'b00100,5'b01000,5'b11111};
                default: glyph_bitmap=35'd0;
            endcase
        end
    endfunction

    function label_pixel;
        input [9:0] x;
        input [2:0] row;
        input [9:0] x0;
        input [2:0] count;
        input [31:0] chars;
        integer cell_index;
        reg [4:0] cell_offset;
        reg [9:0] cell_x;
        reg [7:0] code;
        reg [2:0] column;
        reg [34:0] bitmap;
        reg [4:0] row_bits;
        begin
            label_pixel=1'b0;
            for(cell_index=0;cell_index<4;cell_index=cell_index+1)begin
                cell_offset=({3'd0,cell_index[1:0]}<<2)+({3'd0,cell_index[1:0]}<<1);
                cell_x=x0+{5'd0,cell_offset};
                case(cell_index)
                    0:code=chars[31:24];
                    1:code=chars[23:16];
                    2:code=chars[15:8];
                    default:code=chars[7:0];
                endcase
                if(cell_index<{29'd0,count} && x>=cell_x && x<cell_x+10'd5)begin
                    column=x[2:0]-cell_x[2:0];
                    bitmap=glyph_bitmap(code);
                    case(row)
                        3'd0:row_bits=bitmap[34:30];
                        3'd1:row_bits=bitmap[29:25];
                        3'd2:row_bits=bitmap[24:20];
                        3'd3:row_bits=bitmap[19:15];
                        3'd4:row_bits=bitmap[14:10];
                        3'd5:row_bits=bitmap[9:5];
                        default:row_bits=bitmap[4:0];
                    endcase
                    label_pixel=row_bits[3'd4-column];
                end
            end
        end
    endfunction

    reg [9:0] baseline_y;
    reg [9:0] label_start;
    reg [2:0] label_count;
    reg [31:0] label_chars;
    reg text_row_active;
    reg tick_pixel;
    reg font_pixel;
    reg [2:0] font_row;
    reg [9:0] dy;
    always @* begin
        baseline_y=10'd0;
        label_start=10'd0;
        label_count=3'd0;
        label_chars=32'd0;
        text_row_active=1'b0;
        tick_pixel=1'b0;
        font_pixel=1'b0;
        font_row=3'd0;
        dy=0;

        if(top_panel)begin
            baseline_y=10'd260;
            if(absolute_line>=10'd266 && absolute_line<=10'd272)begin
                text_row_active=1'b1;
                font_row=absolute_line[2:0]-3'd2;
                if(pixel_x<10'd31)begin
                    label_start=10'd8;label_count=3'd4;
                    label_chars=pair_post_active ? {8'h52,8'h41,8'h57,8'h00} : {8'h50,8'h4c,8'h41,8'h59};
                end else if(pixel_x>=10'd590 && pixel_x<10'd601)begin
                    label_start=10'd590;label_count=3'd2;label_chars={8'h48,8'h7a,16'd0};
                end else if(pixel_x>=10'd60 && pixel_x<10'd71)begin
                    label_start=10'd60;label_count=3'd2;label_chars={8'h34,8'h30,16'd0};
                end else if(pixel_x>=10'd135 && pixel_x<10'd152)begin
                    label_start=10'd135;label_count=3'd3;label_chars={8'h31,8'h30,8'h30,8'h00};
                end else if(pixel_x>=10'd169 && pixel_x<10'd186)begin
                    label_start=10'd169;label_count=3'd3;label_chars={8'h31,8'h35,8'h30,8'h00};
                end else if(pixel_x>=10'd253 && pixel_x<10'd270)begin
                    label_start=10'd253;label_count=3'd3;label_chars={8'h34,8'h30,8'h30,8'h00};
                end else if(pixel_x>=10'd332 && pixel_x<10'd343)begin
                    label_start=10'd332;label_count=3'd2;label_chars={8'h31,8'h6b,16'd0};
                end else if(pixel_x>=10'd392 && pixel_x<10'd403)begin
                    label_start=10'd392;label_count=3'd2;label_chars={8'h32,8'h6b,16'd0};
                end else if(pixel_x>=10'd452 && pixel_x<10'd463)begin
                    label_start=10'd452;label_count=3'd2;label_chars={8'h34,8'h6b,16'd0};
                end else if(pixel_x>=10'd512 && pixel_x<10'd523)begin
                    label_start=10'd512;label_count=3'd2;label_chars={8'h38,8'h6b,16'd0};
                end else if(pixel_x>=10'd567 && pixel_x<10'd584)begin
                    label_start=10'd567;label_count=3'd3;label_chars={8'h31,8'h36,8'h6b,8'h00};
                end
                font_pixel=label_pixel(pixel_x,font_row,label_start,label_count,label_chars);
            end
        end else if(bottom_panel)begin
            baseline_y=10'd452;
            if(absolute_line>=10'd458 && absolute_line<=10'd464)begin
                text_row_active=1'b1;
                font_row=absolute_line[2:0]-3'd2;
                if(pixel_x>=10'd8 && pixel_x<10'd31)begin
                    label_start=10'd8;label_count=pair_post_active ? 3'd3 : 3'd4;
                    label_chars=pair_post_active ? {8'h52,8'h41,8'h57,8'h00} : {8'h50,8'h4c,8'h41,8'h59};
                end else if(!single_active && pixel_x>=10'd34 && pixel_x<10'd57)begin
                    label_start=10'd34;label_count=pair_post_active ? 3'd4 : 3'd3;
                    label_chars=pair_post_active ? {8'h50,8'h4f,8'h53,8'h54} : {8'h52,8'h41,8'h57,8'h00};
                end else if(pixel_x>=10'd590 && pixel_x<10'd601)begin
                    label_start=10'd590;label_count=3'd2;label_chars={8'h48,8'h7a,16'd0};
                end else if(pixel_x>=10'd60 && pixel_x<10'd71)begin
                    label_start=10'd60;label_count=3'd2;label_chars={8'h34,8'h30,16'd0};
                end else if(pixel_x>=10'd135 && pixel_x<10'd152)begin
                    label_start=10'd135;label_count=3'd3;label_chars={8'h31,8'h30,8'h30,8'h00};
                end else if(pixel_x>=10'd169 && pixel_x<10'd186)begin
                    label_start=10'd169;label_count=3'd3;label_chars={8'h31,8'h35,8'h30,8'h00};
                end else if(pixel_x>=10'd253 && pixel_x<10'd270)begin
                    label_start=10'd253;label_count=3'd3;label_chars={8'h34,8'h30,8'h30,8'h00};
                end else if(pixel_x>=10'd332 && pixel_x<10'd343)begin
                    label_start=10'd332;label_count=3'd2;label_chars={8'h31,8'h6b,16'd0};
                end else if(pixel_x>=10'd392 && pixel_x<10'd403)begin
                    label_start=10'd392;label_count=3'd2;label_chars={8'h32,8'h6b,16'd0};
                end else if(pixel_x>=10'd452 && pixel_x<10'd463)begin
                    label_start=10'd452;label_count=3'd2;label_chars={8'h34,8'h6b,16'd0};
                end else if(pixel_x>=10'd512 && pixel_x<10'd523)begin
                    label_start=10'd512;label_count=3'd2;label_chars={8'h38,8'h6b,16'd0};
                end else if(pixel_x>=10'd567 && pixel_x<10'd584)begin
                    label_start=10'd567;label_count=3'd3;label_chars={8'h31,8'h36,8'h6b,8'h00};
                end
                font_pixel=label_pixel(pixel_x,font_row,label_start,label_count,label_chars);
            end
        end

        if(top_panel || bottom_panel)begin
            if(absolute_line==baseline_y && x_in_plot)tick_pixel=1'b1;
            dy=absolute_line-baseline_y;
            if(dy>=10'd1 && dy<=10'd3 && (pixel_x==10'd65 || pixel_x==10'd143 || pixel_x==10'd177 ||
               pixel_x==10'd261 || pixel_x==10'd337 || pixel_x==10'd397 || pixel_x==10'd457 ||
               pixel_x==10'd517 || pixel_x==10'd575))tick_pixel=1'b1;
            if(pixel_x==10'd177 && dy>=10'd1 && dy<=10'd5)tick_pixel=1'b1;
        end
    end

    assign axis_text=de && (top_panel || bottom_panel) && (tick_pixel || (text_row_active && font_pixel));
endmodule

