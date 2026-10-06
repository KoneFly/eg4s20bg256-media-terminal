`timescale 1ns/1ps
// 离线LRC字节解析：可背压输入，分离时间项/正文/行结束，缓存未完成前不发布。
module lrc_tokenizer(
    input wire clk,input wire rst,input wire start,input wire cancel,
    input wire in_valid,input wire [7:0] in_byte,input wire in_last,output wire in_ready,
    output reg timestamp_valid,output reg [31:0] timestamp_samples,input wire timestamp_ready,
    output reg character_valid,output reg [7:0] character,input wire character_ready,
    output reg line_done,input wire line_ready,output reg finish,output reg bad_format
);
    localparam [3:0] IDLE=0,BYTE=1,EMIT_CHAR=2,EMIT_LITERAL=3,LINE=4,
        SAMPLE=5,TIME=6,DONE=7,ACCUMULATE=8;
    localparam [1:0] PREFIX=0,TAG=1,TEXT=2,IGNORE=3;
    reg [3:0] state;
    reg [1:0] mode,utf_left;
    reg [3:0] digit_position;
    reg [19:0] centis;
    reg [3:0] remaining_digit;
    reg [15:0] unit_weight;
    always @*case(digit_position)
        0:unit_weight=16'd60000;1:unit_weight=16'd6000;
        3:unit_weight=16'd1000;4:unit_weight=16'd100;
        6:unit_weight=16'd10;default:unit_weight=16'd1;
    endcase
    reg has_time,end_pending,pending_literal;
    reg [7:0] literal_byte;
    reg [1:0] bom;
    reg first_byte;
    assign in_ready=(state==BYTE) && !cancel;
    wire digit=in_byte>=8'h30 && in_byte<=8'h39;
    always @(posedge clk or posedge rst) begin
        if(rst)begin
            state<=IDLE;mode<=PREFIX;utf_left<=0;digit_position<=0;
            centis<=0;remaining_digit<=0;
            has_time<=0;end_pending<=0;pending_literal<=0;literal_byte<=0;bom<=0;first_byte<=1;
            timestamp_valid<=0;timestamp_samples<=0;character_valid<=0;character<=0;
            line_done<=0;finish<=0;bad_format<=0;
        end else if(cancel)begin
            state<=IDLE;timestamp_valid<=0;character_valid<=0;line_done<=0;finish<=0;bad_format<=0;
        end else begin
            finish<=0;
            case(state)
                IDLE:if(start)begin
                    state<=BYTE;mode<=PREFIX;utf_left<=0;has_time<=0;end_pending<=0;
                    bom<=0;first_byte<=1;pending_literal<=0;bad_format<=0;
                end
                BYTE:if(in_valid)begin
                    first_byte<=0;
                    if(in_last)end_pending<=1;
                    if(first_byte && in_byte==8'hEF)begin if(in_last)begin bad_format<=1;state<=DONE;end else bom<=1;end
                    else if(bom==1)begin if(in_byte==8'hBB && !in_last)bom<=2;else begin bad_format<=1;state<=DONE;end end
                    else if(bom==2)begin if(in_byte==8'hBF)begin bom<=0;if(in_last)state<=DONE;end else begin bad_format<=1;state<=DONE;end end
                    else if(in_byte==8'h0A || in_byte==8'h0D)begin
                        if(mode==TAG || utf_left!=0)begin bad_format<=1;state<=DONE;end
                        else begin line_done<=has_time;state<=LINE;end
                    end else if(mode==IGNORE)begin if(in_last)state<=DONE;end
                    else if(mode==TAG)begin
                        case(digit_position)
                            0:begin
                                if(digit)begin centis<=0;remaining_digit<=in_byte[3:0];state<=ACCUMULATE;end
                                else if(has_time)begin
                                    character<=8'h5B;character_valid<=1;pending_literal<=1;
                                    literal_byte<=in_byte;mode<=TEXT;state<=EMIT_CHAR;
                                end else begin mode<=IGNORE;if(in_last)state<=DONE;end
                            end
                            1:if(digit)begin remaining_digit<=in_byte[3:0];state<=ACCUMULATE;end
                              else begin bad_format<=1;state<=DONE;end
                            2:if(in_byte==8'h3A)digit_position<=3;else begin bad_format<=1;state<=DONE;end
                            3:if(digit && in_byte<=8'h35)begin remaining_digit<=in_byte[3:0];state<=ACCUMULATE;end
                              else begin bad_format<=1;state<=DONE;end
                            4:if(digit)begin remaining_digit<=in_byte[3:0];state<=ACCUMULATE;end
                              else begin bad_format<=1;state<=DONE;end
                            5:if(in_byte==8'h2E)digit_position<=6;else begin bad_format<=1;state<=DONE;end
                            6:if(digit)begin remaining_digit<=in_byte[3:0];state<=ACCUMULATE;end
                              else begin bad_format<=1;state<=DONE;end
                            7:if(digit)begin remaining_digit<=in_byte[3:0];state<=ACCUMULATE;end
                              else begin bad_format<=1;state<=DONE;end
                            default:if(in_byte==8'h5D)state<=SAMPLE;else begin bad_format<=1;state<=DONE;end
                        endcase
                        if(in_last && !(digit_position==8 && in_byte==8'h5D))begin bad_format<=1;state<=DONE;end
                    end else if(mode==PREFIX && in_byte==8'h5B)begin
                        mode<=TAG;digit_position<=0;
                        if(in_last)begin bad_format<=1;state<=DONE;end
                    end else if(!has_time)begin mode<=IGNORE;if(in_last)state<=DONE;end
                    else begin
                        mode<=TEXT;
                        if(utf_left!=0)begin
                            if(in_byte[7:6]==2'b10)begin
                                utf_left<=utf_left-1'b1;
                                if(in_last)begin if(utf_left==1)begin line_done<=1;state<=LINE;end else begin bad_format<=1;state<=DONE;end end
                            end else begin bad_format<=1;state<=DONE;end
                        end else if(in_byte>=8'h7F)begin
                            character<=8'h3F;character_valid<=1;state<=EMIT_CHAR;
                            if(in_byte>=8'hC2&&in_byte<=8'hDF)utf_left<=1;
                            else if(in_byte>=8'hE0&&in_byte<=8'hEF)utf_left<=2;
                            else if(in_byte>=8'hF0&&in_byte<=8'hF4)utf_left<=3;
                        end else if(in_byte>=8'h20 || in_byte==8'h09)begin
                            character<=(in_byte==8'h09)?8'h20:in_byte;character_valid<=1;state<=EMIT_CHAR;
                        end else begin bad_format<=1;state<=DONE;end
                    end
                end
                ACCUMULATE:if(remaining_digit!=0)begin
                    centis<=centis+{4'd0,unit_weight};remaining_digit<=remaining_digit-4'd1;
                end else begin digit_position<=digit_position+4'd1;state<=BYTE;end
                SAMPLE:begin
                    timestamp_samples<=({12'd0,centis}<<9)-({12'd0,centis}<<5);
                    timestamp_valid<=1;state<=TIME;
                end
                TIME:if(timestamp_ready)begin
                    timestamp_valid<=0;has_time<=1;mode<=PREFIX;
                    if(end_pending)begin line_done<=1;state<=LINE;end else state<=BYTE;
                end
                EMIT_CHAR:if(character_ready)begin
                    character_valid<=0;
                    if(pending_literal)begin pending_literal<=0;state<=EMIT_LITERAL;end
                    else if(end_pending)begin
                        if(utf_left!=0)begin bad_format<=1;state<=DONE;end
                        else begin line_done<=1;state<=LINE;end
                    end else state<=BYTE;
                end
                EMIT_LITERAL:begin
                    character<=(literal_byte==8'h09)?8'h20:(literal_byte>=8'h20&&literal_byte<8'h7F)?literal_byte:8'h3F;
                    if(literal_byte>=8'hC2&&literal_byte<=8'hDF)utf_left<=1;
                    else if(literal_byte>=8'hE0&&literal_byte<=8'hEF)utf_left<=2;
                    else if(literal_byte>=8'hF0&&literal_byte<=8'hF4)utf_left<=3;
                    character_valid<=1;state<=EMIT_CHAR;
                end
                LINE:if(!line_done || line_ready)begin
                    line_done<=0;has_time<=0;mode<=PREFIX;utf_left<=0;
                    if(end_pending)state<=DONE;else state<=BYTE;
                end
                DONE:begin
                    timestamp_valid<=0;character_valid<=0;line_done<=0;finish<=1;state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
