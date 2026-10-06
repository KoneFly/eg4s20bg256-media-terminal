`timescale 1ns/1ps
// CTRL保持快照在pixel域捕获，顺序转BCD并生成四行仪表盘与说明条ASCII，仅写非活动文本银行。
module dashboard_format (
    input wire clk,
    input wire rst,
    input wire snapshot_toggle,
    input wire [102:0] snapshot_data,
    output reg snapshot_acknowledge,
    input wire [1:0] brightness,
    input wire [1:0] contrast,
    input wire [23:0] played_bcd,
    input wire played_valid,
    input wire [23:0] up_bcd,
    input wire [23:0] total_bcd,
    input wire total_valid,
    output reg [31:0] file_bytes,
    output reg file_present,
    output reg file_update,
    input wire text_acknowledge,
    output reg text_ready_toggle,
    output wire text_ready_bank,
    output wire text_help_adjust,
    output wire write_enable,
    output wire [8:0] write_address,
    output wire [7:0] write_character
);
    localparam [1:0] IDLE=2'd0, DECIMAL=2'd1, WAIT_TOTAL=2'd2, WRITE=2'd3;
    reg [1:0] state;
    (* async_reg = "true" *) reg [1:0] request_sync;
    reg [47:0] dimensions;
    reg [63:0] dimensions_bcd;
    reg [31:0] shift_reg;
    reg [3:0] digit_cycle;
    reg [1:0] dimension_index;
    reg [1:0] track_slot, brightness_r, contrast_r;
    reg image_ready, auto_r, adjust_r, option_r, played_valid_r;
    reg [23:0] played_r, total_r, up_r;
    reg [7:0] position;
    wire write_bank = ~text_ready_toggle;
    assign text_ready_bank = text_ready_toggle;
    assign text_help_adjust = adjust_r;
    function [3:0] add_three;
        input [3:0] v;
        begin add_three=(v >= 4'd5) ? v+4'd3 : v; end
    endfunction
    wire [31:0] adjusted = {add_three(shift_reg[31:28]),add_three(shift_reg[27:24]),
                           add_three(shift_reg[23:20]),add_three(shift_reg[19:16]),shift_reg[15:0]};
    wire [31:0] shifted = {adjusted[30:0],1'b0};
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            request_sync <= 2'b00;
            snapshot_acknowledge <= 1'b0;
            state <= IDLE;
            dimensions <= 48'd0;
            dimensions_bcd <= 64'd0;
            shift_reg <= 32'd0;
            digit_cycle <= 4'd0;
            dimension_index <= 2'd0;
            file_bytes <= 32'd0;
            file_present <= 1'b0;
            file_update <= 1'b0;
            track_slot <= 2'd0;
            brightness_r <= 2'd0;
            contrast_r <= 2'd1;
            image_ready <= 1'b0;
            auto_r <= 1'b0;
            adjust_r <= 1'b0;
            option_r <= 1'b0;
            played_valid_r <= 1'b0;
            played_r <= 24'd0;
            total_r <= 24'd0;
            up_r <= 24'd0;
            position <= 8'd0;
            text_ready_toggle <= 1'b0;
        end else begin
            request_sync <= {request_sync[0],snapshot_toggle};
            file_update <= 1'b0;
            case (state)
                IDLE: begin
                    if (request_sync[1] != snapshot_acknowledge &&
                        text_ready_toggle == text_acknowledge) begin
                        dimensions <= snapshot_data[86:39];
                        shift_reg <= {16'd0,snapshot_data[102:87]};
                        file_bytes <= snapshot_data[38:7];
                        file_update <= 1'b1;
                        track_slot <= snapshot_data[6:5];
                        file_present <= snapshot_data[4];
                        image_ready <= snapshot_data[3];
                        auto_r <= snapshot_data[2];
                        adjust_r <= snapshot_data[1];
                        option_r <= snapshot_data[0];
                        brightness_r <= brightness;
                        contrast_r <= contrast;
                        played_r <= played_bcd;
                        played_valid_r <= played_valid;
                        up_r <= up_bcd;
                        snapshot_acknowledge <= request_sync[1];
                        dimension_index <= 2'd0;
                        digit_cycle <= 4'd0;
                        state <= DECIMAL;
                    end
                end
                DECIMAL: begin
                    shift_reg <= shifted;
                    if (digit_cycle == 4'd15) begin
                        digit_cycle <= 4'd0;
                        case (dimension_index)
                            2'd0: begin
                                dimensions_bcd[63:48] <= shifted[31:16];
                                shift_reg <= {16'd0,dimensions[47:32]};
                            end
                            2'd1: begin
                                dimensions_bcd[47:32] <= shifted[31:16];
                                shift_reg <= {16'd0,dimensions[47:32]};
                            end
                            2'd2: begin
                                dimensions_bcd[31:16] <= shifted[31:16];
                                shift_reg <= {16'd0,dimensions[47:32]};
                            end
                            default: begin
                                dimensions_bcd[15:0] <= shifted[31:16];
                                state <= WAIT_TOTAL;
                            end
                        endcase
                        dimensions <= {dimensions[31:0],16'd0};
                        dimension_index <= dimension_index + 2'd1;
                    end else begin
                        digit_cycle <= digit_cycle + 4'd1;
                    end
                end
                WAIT_TOTAL: begin
                    if (!file_present || total_valid) begin
                        total_r <= total_bcd;
                        // 播放器读取整扇区，末扇区填充不应让进度超过目录有效时长。
                        if(file_present && played_r > total_bcd) played_r <= total_bcd;
                        position <= 8'd0;
                        state <= WRITE;
                    end
                end
                WRITE: begin
                    if (position == 8'd255) begin
                        text_ready_toggle <= ~text_ready_toggle;
                        state <= IDLE;
                    end else begin
                        position <= position + 8'd1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
    assign write_enable=(state == WRITE);
    assign write_address={write_bank,position};

    function [7:0] decimal_char;
        input [15:0] bcd;
        input [1:0] digit;
        input valid;
        reg [3:0] value;
        begin
            case (digit)
                2'd0:value=bcd[15:12];
                2'd1:value=bcd[11:8];
                2'd2:value=bcd[7:4];
                default:value=bcd[3:0];
            endcase
            decimal_char=valid ? {4'h3,value} : 8'h2D;
        end
    endfunction
    function [7:0] time_char;
        input [23:0] bcd;
        input [2:0] digit;
        input valid;
        begin
            if (!valid) begin
                case (digit)
                    3'd2,3'd3,3'd5,3'd6:time_char=8'h2D;
                    3'd4:time_char=8'h3A;
                    default:time_char=8'h20;
                endcase
            end else begin
                case (digit)
                    3'd0:time_char={4'h3,bcd[23:20]};
                    3'd1:time_char={4'h3,bcd[19:16]};
                    3'd2:time_char=8'h3A;
                    3'd3:time_char={4'h3,bcd[15:12]};
                    3'd4:time_char={4'h3,bcd[11:8]};
                    3'd5:time_char=8'h3A;
                    3'd6:time_char={4'h3,bcd[7:4]};
                    default:time_char={4'h3,bcd[3:0]};
                endcase
            end
        end
    endfunction
    // 只读文案RAM同步一拍读；以当前位置的下一列预取，对齐下一拍实际写字节。
    wire [6:0] help_next_column=position[6:0]+7'd1;
    wire [8:0] help_rom_address={1'b0,adjust_r,help_next_column};
    wire [7:0] help_rom_character;
`ifdef SIMULATION
    reg [7:0] help_rom [0:1023];
    reg [7:0] help_rom_q;
    integer help_init;
    initial begin
        for(help_init=0;help_init<1024;help_init=help_init+1) help_rom[help_init]=8'h20;
        help_rom[0]=8'h4B;
        help_rom[1]=8'h31;
        help_rom[3]=8'h52;
        help_rom[4]=8'h53;
        help_rom[5]=8'h54;
        help_rom[7]=8'h7C;
        help_rom[9]=8'h4B;
        help_rom[10]=8'h32;
        help_rom[12]=8'h4E;
        help_rom[13]=8'h45;
        help_rom[14]=8'h58;
        help_rom[15]=8'h54;
        help_rom[17]=8'h7C;
        help_rom[19]=8'h4B;
        help_rom[20]=8'h34;
        help_rom[22]=8'h50;
        help_rom[23]=8'h52;
        help_rom[24]=8'h45;
        help_rom[25]=8'h56;
        help_rom[28]=8'h4B;
        help_rom[29]=8'h32;
        help_rom[31]=8'h48;
        help_rom[32]=8'h4F;
        help_rom[33]=8'h4C;
        help_rom[34]=8'h44;
        help_rom[36]=8'h46;
        help_rom[37]=8'h55;
        help_rom[38]=8'h4C;
        help_rom[39]=8'h4C;
        help_rom[40]=8'h2F;
        help_rom[41]=8'h42;
        help_rom[42]=8'h41;
        help_rom[43]=8'h43;
        help_rom[44]=8'h4B;
        help_rom[46]=8'h7C;
        help_rom[48]=8'h4B;
        help_rom[49]=8'h33;
        help_rom[51]=8'h50;
        help_rom[52]=8'h4C;
        help_rom[53]=8'h41;
        help_rom[54]=8'h59;
        help_rom[56]=8'h48;
        help_rom[57]=8'h4F;
        help_rom[58]=8'h4C;
        help_rom[59]=8'h44;
        help_rom[61]=8'h53;
        help_rom[62]=8'h4F;
        help_rom[63]=8'h4E;
        help_rom[64]=8'h47;
        help_rom[67]=8'h53;
        help_rom[68]=8'h57;
        help_rom[69]=8'h31;
        help_rom[71]=8'h41;
        help_rom[72]=8'h44;
        help_rom[73]=8'h4A;
        help_rom[75]=8'h7C;
        help_rom[77]=8'h53;
        help_rom[78]=8'h57;
        help_rom[79]=8'h32;
        help_rom[81]=8'h41;
        help_rom[82]=8'h55;
        help_rom[83]=8'h54;
        help_rom[84]=8'h4F;
        help_rom[87]=8'h4B;
        help_rom[88]=8'h32;
        help_rom[89]=8'h2B;
        help_rom[90]=8'h4B;
        help_rom[91]=8'h34;
        help_rom[93]=8'h48;
        help_rom[94]=8'h4F;
        help_rom[95]=8'h4C;
        help_rom[96]=8'h44;
        help_rom[98]=8'h52;
        help_rom[99]=8'h45;
        help_rom[100]=8'h53;
        help_rom[101]=8'h43;
        help_rom[102]=8'h41;
        help_rom[103]=8'h4E;
        help_rom[105]=8'h7C;
        help_rom[107]=8'h4B;
        help_rom[108]=8'h32;
        help_rom[109]=8'h2B;
        help_rom[110]=8'h4B;
        help_rom[111]=8'h33;
        help_rom[113]=8'h48;
        help_rom[114]=8'h4F;
        help_rom[115]=8'h4C;
        help_rom[116]=8'h44;
        help_rom[118]=8'h4D;
        help_rom[119]=8'h45;
        help_rom[120]=8'h54;
        help_rom[121]=8'h52;
        help_rom[122]=8'h49;
        help_rom[123]=8'h43;
        help_rom[124]=8'h53;
        help_rom[128]=8'h4B;
        help_rom[129]=8'h32;
        help_rom[131]=8'h2B;
        help_rom[133]=8'h7C;
        help_rom[135]=8'h4B;
        help_rom[136]=8'h33;
        help_rom[138]=8'h2D;
        help_rom[140]=8'h7C;
        help_rom[142]=8'h4B;
        help_rom[143]=8'h34;
        help_rom[145]=8'h4F;
        help_rom[146]=8'h50;
        help_rom[147]=8'h54;
        help_rom[149]=8'h7C;
        help_rom[151]=8'h53;
        help_rom[152]=8'h57;
        help_rom[153]=8'h31;
        help_rom[155]=8'h45;
        help_rom[156]=8'h58;
        help_rom[157]=8'h49;
        help_rom[158]=8'h54;
    end
    always @(posedge clk) help_rom_q<=help_rom[{1'b0,help_rom_address}];
    assign help_rom_character=help_rom_q;
`else
    wire [8:0] help_rom_word;
    EG_PHY_BRAM #(
        .CEAMUX("1"),.CEBMUX("1"),.CSA0("1"),.CSA1("1"),.CSA2("1"),
        .CSB0("1"),.CSB1("1"),.CSB2("1"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),
        .MODE("DP8K"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.RESETMODE("SYNC"),
        .RSTAMUX("0"),.RSTBMUX("0"),.WEBMUX("0"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
        .INITP_00(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INITP_01(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INITP_02(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INITP_03(256'h0000000000000000000000000000000000000000000000000000000000000000),
        .INIT_00(256'h4820324B20205645525020344B207C205458454E20324B207C2054535220314B),
        .INIT_01(256'h4E4F5320444C4F482059414C5020334B207C204B4341422F4C4C554620444C4F),
        .INIT_02(256'h4C4F4820344B2B324B20204F54554120325753207C204A444120315753202047),
        .INIT_03(256'h2020205343495254454D20444C4F4820334B2B324B207C204E41435345522044),
        .INIT_04(256'h205449584520315753207C2054504F20344B207C202D20334B207C202B20324B),
        .INIT_05(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_06(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_07(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_08(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_09(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_0A(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_0B(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_0C(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_0D(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_0E(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_0F(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_10(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_11(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_12(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_13(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_14(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_15(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_16(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_17(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_18(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_19(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_1A(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_1B(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_1C(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_1D(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_1E(256'h2020202020202020202020202020202020202020202020202020202020202020),
        .INIT_1F(256'h2020202020202020202020202020202020202020202020202020202020202020)
    ) u_help_rom (
        .dia(9'd0),.addra({1'b0,help_rom_address,3'b111}),.csa(3'b111),
        .cea(1'b1),.ocea(1'b0),.clka(clk),.wea(1'b0),.rsta(1'b0),.doa(help_rom_word),
        .dib(9'd0),.addrb(13'd0),.csb(3'd0),.ceb(1'b0),.oceb(1'b0),.clkb(clk),.web(1'b0),.rstb(1'b0),.dob()
    );
    assign help_rom_character=help_rom_word[7:0];
`endif
    reg [7:0] character;
    wire [4:0] column=position[4:0];
    wire [4:0] src_h_position=column-5'd9;
    wire [4:0] view_h_position=column-5'd21;
    wire [4:0] played_position=column-5'd5;
    wire [4:0] total_position=column-5'd14;
    wire [4:0] up_position=column-5'd3;
    wire [6:0] help_length=adjust_r?7'd31:7'd125;
    // 每行最后一字节保存实际字符数，显示端只在行前导区读取，不把填充空格算入背景。
    always @* begin
        character=8'h20;
        if(position[7]) begin
            if(position[6:0]==7'd127) character={1'b0,help_length};
            else character=help_rom_character;
        end else case(position[6:5])
            2'd0:begin
                if(column==5'd31) character=8'd25;
                else if(column>=5'd4 && column<=5'd7) character=decimal_char(dimensions_bcd[63:48],column[1:0],image_ready);
                else if(column>=5'd9 && column<=5'd12) character=decimal_char(dimensions_bcd[47:32],src_h_position[1:0],image_ready);
                else if(column>=5'd16 && column<=5'd19) character=decimal_char(dimensions_bcd[31:16],column[1:0],image_ready);
                else if(column>=5'd21 && column<=5'd24) character=decimal_char(dimensions_bcd[15:0],view_h_position[1:0],image_ready);
                else case(column)
                    5'd0:character=8'h53;5'd1:character=8'h52;5'd2:character=8'h43;
                    5'd8,5'd20:character=8'h78;5'd14:character=8'h56;default:character=8'h20;endcase
            end
            2'd1:begin
                case(column)
                    5'd31:character=8'd27;
                    5'd0:character=8'h42;5'd1:character=8'h2B;5'd2:character=8'h30;
                    5'd3:case(brightness_r)2'd0:character=8'h30;2'd1:character=8'h33;2'd2:character=8'h36;default:character=8'h39;endcase
                    5'd4:case(brightness_r)2'd0:character=8'h30;2'd1:character=8'h32;2'd2:character=8'h34;default:character=8'h36;endcase
                    5'd6:character=8'h43;
                    5'd7:case(contrast_r)2'd0:character=8'h30;2'd3:character=8'h32;default:character=8'h31;endcase
                    5'd8:character=8'h2E;5'd9:character=(contrast_r==2'd2) ? 8'h35 : 8'h30;
                    5'd11:character=8'h41;5'd12:character=8'h55;5'd13:character=8'h54;5'd14,5'd16:character=8'h4F;
                    5'd17:character=auto_r?8'h4E:8'h46;5'd18:character=auto_r?8'h20:8'h46;
                    5'd20:character=8'h41;5'd21:character=8'h44;5'd22:character=8'h4A;
                    5'd24:character=!adjust_r?8'h4F:option_r?8'h43:8'h42;
                    5'd25:character=!adjust_r?8'h46:option_r?8'h4F:8'h52;
                    5'd26:character=!adjust_r?8'h46:option_r?8'h4E:8'h49;
                    default:character=8'h20;
                endcase
            end
            2'd2:begin
                if(column==5'd31) character=file_present?8'd22:8'd21;
                else if(column>=5'd5 && column<=5'd12) character=time_char(played_r,played_position[2:0],file_present&&played_valid_r);
                else if(column>=5'd14 && column<=5'd21) character=time_char(total_r,total_position[2:0],file_present);
                else case(column)
                    5'd0:character=8'h54;5'd1:character=8'h52;5'd2:character=8'h4B;
                    5'd3:character=file_present?(8'h31+{6'd0,track_slot}):8'h2D;5'd13:character=8'h2F;
                    default:character=8'h20;endcase
            end
            default:begin
                if(column==5'd31) character=8'd11;
                else if(column>=5'd3 && column<=5'd10) character=time_char(up_r,up_position[2:0],1'b1);
                else case(column)5'd0:character=8'h55;5'd1:character=8'h50;default:character=8'h20;endcase
            end
        endcase
    end
    assign write_character=character;
endmodule
