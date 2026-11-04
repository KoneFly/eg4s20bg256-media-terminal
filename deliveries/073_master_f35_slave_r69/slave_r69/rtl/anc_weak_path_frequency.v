`timescale 1ns/1ps
// 单频控制：校准声路强度分档调整步长；PCM上限8192，L1系数预算限制更新；输入/时序/校准保护保持。
// 所有乘法共用一个24x16流水数据通路；输入有效间隔为1040个50MHz周期。
module anc_weak_path_frequency (
    input  wire clk,
    input  wire rst_n,
    input  wire enable,
    input  wire command,
    input  wire [1:0] tone_select,
    input wire override_enable,
    input wire [31:0] override_increment,
    output wire signed [15:0] basis_sine,basis_cosine,
    output reg basis_valid,
    input wire [31:0] tracking_increment,
    output wire [31:0] reference_increment,
    output wire signed [23:0] weight_c_state,weight_s_state,
    output reg adaptation_done,
    output reg limit_reached,
    input  wire sample_valid,
    input  wire signed [15:0] error_sample,
    output reg sample_out_valid,
    output reg signed [15:0] sample_out,
    output wire ready,
    output wire calibrating,
    output wire fault
);
    localparam [2:0] M_ARM=3'd0, M_SETTLE=3'd1, M_CAL=3'd2,
                     M_RUN=3'd3, M_FAULT=3'd4;
    localparam [4:0] E_IDLE=5'd0, E_SIN=5'd1, E_COS=5'd2,
        E_FSIN=5'd3, E_FCOS=5'd4, E_DISPATCH=5'd5,
        E_CAL_C_WAIT=5'd6, E_CAL_C_GET=5'd7,
        E_CAL_S_WAIT=5'd8, E_CAL_S_GET=5'd9, E_NORM=5'd10,
        E_SCAN_SIN=5'd11, E_SCAN_COS=5'd12, E_SCAN_SET=5'd13,
        E_SCAN_C_WAIT=5'd14, E_SCAN_C_GET=5'd15,
        E_SCAN_S_WAIT=5'd16, E_SCAN_S_GET=5'd17,
        E_YC_WAIT=5'd18, E_YC_GET=5'd19,
        E_YS_WAIT=5'd20, E_YS_GET=5'd21,
        E_GC_WAIT=5'd22, E_GC_GET=5'd23,
        E_GS_WAIT=5'd24, E_GS_GET=5'd25;
    reg [1:0] selected_tone;
    wire [31:0] preset_increment = tone_select == 2'd0 ? 32'd22333830 :
                                  tone_select == 2'd2 ? 32'd67001490 :
                                  32'd44667660;
    reg [31:0] selected_increment;
    reg signed [23:0] weight_c, weight_s;
    wire [31:0] phase_increment=ready ? tracking_increment : selected_increment;
    assign reference_increment=selected_increment;
    assign weight_c_state=weight_c,weight_s_state=weight_s;
    wire override_valid=override_increment>=32'd3573413 && override_increment<=32'd89245984;
    localparam signed [31:0] PCM_LIMIT=32'sd8192;
    localparam signed [31:0] COEFF_LIMIT=32'sd8388607;
    localparam [47:0] MIN_CAL_CORR=48'd1638400000;

    reg [2:0] mode;
    reg [4:0] engine;
    reg [31:0] phase;
    reg [7:0] theta, lookup_angle, phase_offset;
    reg signed [16:0] error_q;
    reg signed [15:0] sine_q, cosine_q, fsine_q, fcosine_q;
    reg signed [31:0] error_dc_q8;
    wire signed [31:0] error_input_q8={{8{error_sample[15]}},error_sample,8'd0};
    wire signed [31:0] error_dc_delta=error_input_q8-error_dc_q8;
    wire signed [16:0] centered_error=$signed({error_sample[15],error_sample})-$signed({error_dc_q8[23],error_dc_q8[23:8]});
    reg [13:0] settle_count;
    reg [13:0] cal_count;
    reg signed [47:0] cal_c, cal_s, norm_c, norm_s;
    reg signed [15:0] path_c, path_s;
    reg [5:0] scan_index;
    reg [5:0] calibration_shift;
    reg [2:0] adaptation_scale;
    reg signed [23:0] adaptation_error;
    reg [7:0] best_phase;
    reg signed [39:0] best_score, sum_product;
    reg signed [23:0] mul_a;
    reg signed [15:0] mul_b;
    reg signed [39:0] product;

    // 数据寄存器不复位；状态机只在对应乘法已完成时消费product。
    always @(posedge clk)
        product <= mul_a * mul_b;

    function signed [15:0] quarter;
        input [6:0] index;
        begin
            case(index)
                7'd0: quarter = 16'sd0;
                7'd1: quarter = 16'sd804;
                7'd2: quarter = 16'sd1608;
                7'd3: quarter = 16'sd2410;
                7'd4: quarter = 16'sd3212;
                7'd5: quarter = 16'sd4011;
                7'd6: quarter = 16'sd4808;
                7'd7: quarter = 16'sd5602;
                7'd8: quarter = 16'sd6393;
                7'd9: quarter = 16'sd7179;
                7'd10: quarter = 16'sd7962;
                7'd11: quarter = 16'sd8739;
                7'd12: quarter = 16'sd9512;
                7'd13: quarter = 16'sd10278;
                7'd14: quarter = 16'sd11039;
                7'd15: quarter = 16'sd11793;
                7'd16: quarter = 16'sd12539;
                7'd17: quarter = 16'sd13279;
                7'd18: quarter = 16'sd14010;
                7'd19: quarter = 16'sd14732;
                7'd20: quarter = 16'sd15446;
                7'd21: quarter = 16'sd16151;
                7'd22: quarter = 16'sd16846;
                7'd23: quarter = 16'sd17530;
                7'd24: quarter = 16'sd18204;
                7'd25: quarter = 16'sd18868;
                7'd26: quarter = 16'sd19519;
                7'd27: quarter = 16'sd20159;
                7'd28: quarter = 16'sd20787;
                7'd29: quarter = 16'sd21403;
                7'd30: quarter = 16'sd22005;
                7'd31: quarter = 16'sd22594;
                7'd32: quarter = 16'sd23170;
                7'd33: quarter = 16'sd23731;
                7'd34: quarter = 16'sd24279;
                7'd35: quarter = 16'sd24811;
                7'd36: quarter = 16'sd25329;
                7'd37: quarter = 16'sd25832;
                7'd38: quarter = 16'sd26319;
                7'd39: quarter = 16'sd26790;
                7'd40: quarter = 16'sd27245;
                7'd41: quarter = 16'sd27683;
                7'd42: quarter = 16'sd28105;
                7'd43: quarter = 16'sd28510;
                7'd44: quarter = 16'sd28898;
                7'd45: quarter = 16'sd29268;
                7'd46: quarter = 16'sd29621;
                7'd47: quarter = 16'sd29956;
                7'd48: quarter = 16'sd30273;
                7'd49: quarter = 16'sd30571;
                7'd50: quarter = 16'sd30852;
                7'd51: quarter = 16'sd31113;
                7'd52: quarter = 16'sd31356;
                7'd53: quarter = 16'sd31580;
                7'd54: quarter = 16'sd31785;
                7'd55: quarter = 16'sd31971;
                7'd56: quarter = 16'sd32137;
                7'd57: quarter = 16'sd32285;
                7'd58: quarter = 16'sd32412;
                7'd59: quarter = 16'sd32521;
                7'd60: quarter = 16'sd32609;
                7'd61: quarter = 16'sd32678;
                7'd62: quarter = 16'sd32728;
                7'd63: quarter = 16'sd32757;
                7'd64: quarter = 16'sd32767;
                default: quarter = 16'sd0;
            endcase
        end
    endfunction

    function signed [15:0] sine256;
        input [7:0] angle;
        reg [6:0] address;
        reg signed [15:0] magnitude;
        begin
            if(angle[6]) address=7'd64-{1'b0,angle[5:0]};
            else address={1'b0,angle[5:0]};
            magnitude=quarter(address);
            sine256=angle[7] ? -magnitude : magnitude;
        end
    endfunction

    // 最近整数，恰在半数时远离零；避免负数算术右移的直流偏置。
    function signed [31:0] rounded;
        input signed [40:0] value;
        input [5:0] amount;
        reg signed [40:0] floor_value;
        reg [40:0] low_mask, low_bits, half_value;
        reg round_up;
        begin
            // 负数恰半不向零进位，与最近整数、恰半远离零完全相同。
            floor_value=value>>>amount;
            low_mask=(41'd1<<amount)-41'd1;
            low_bits=value&low_mask;
            half_value=41'd1<<(amount-6'd1);
            round_up=value[40] ? (low_bits>half_value) : (low_bits>=half_value);
            rounded=floor_value[31:0]+{31'd0,round_up};
        end
    endfunction



    assign basis_sine=sine_q,basis_cosine=cosine_q;
    wire signed [15:0] lookup_value=sine256(lookup_angle);
    wire signed [47:0] cal_s_next=cal_s+{{8{product[39]}},product};
    // 只判断是否跨过固定幅值门槛，无需计算绝对值再取最大。
    wire calibration_too_weak =
        (cal_c > -$signed(MIN_CAL_CORR)) && (cal_c < $signed(MIN_CAL_CORR)) &&
        (cal_s_next > -$signed(MIN_CAL_CORR)) && (cal_s_next < $signed(MIN_CAL_CORR));
    wire normalization_needed =
        (norm_c >= 48'sd16384) || (norm_c <= -48'sd16384) ||
        (norm_s >= 48'sd16384) || (norm_s <= -48'sd16384);
    wire signed [40:0] total_product={sum_product[39],sum_product}
                                      +{product[39],product};
    wire signed [31:0] output_pcm=rounded(total_product,6'd24);
    // 固定布线移位与小规模选择，避免在乘积端引入宽可变移位器。
    always @* begin
        case(adaptation_scale)
            1:adaptation_error={{6{error_q[16]}},error_q,1'd0};
            2:adaptation_error={{5{error_q[16]}},error_q,2'd0};
            3:adaptation_error={{4{error_q[16]}},error_q,3'd0};
            4:adaptation_error={{3{error_q[16]}},error_q,4'd0};
            5:adaptation_error={{2{error_q[16]}},error_q,5'd0};
            6:adaptation_error={{1{error_q[16]}},error_q,6'd0};
            default:adaptation_error={{7{error_q[16]}},error_q};
        endcase
    end
    wire signed [31:0] gradient=rounded({product[39],product},6'd17);
    wire signed [31:0] next_c={{8{weight_c[23]}},weight_c}-gradient;
    wire signed [31:0] next_s={{8{weight_s[23]}},weight_s}-gradient;
    // |wc|+|ws|<=2^22保证任意相位的整数PCM峰值不超过8192。
    // 只拒绝把系数推到预算外的更新，不削平PCM；允许反向更新恢复。
    localparam [32:0] COEFF_SUM_LIMIT=33'd4194304;
    wire [23:0] weight_c_abs=weight_c[23] ? -weight_c : weight_c;
    wire [23:0] weight_s_abs=weight_s[23] ? -weight_s : weight_s;
    // |next|+|other|<=L精确等价于|other|<=L且next处于[-gap,+gap]。
    // gap只由旧权值决定，移除乘积支路上的绝对值和预算求和两段进位链。
    wire [24:0] c_gap=25'd4194304-{1'b0,weight_s_abs};
    wire [24:0] s_gap=25'd4194304-{1'b0,weight_c_abs};
    wire signed [31:0] c_upper=$signed({7'd0,c_gap}),s_upper=$signed({7'd0,s_gap});
    wire signed [31:0] c_lower=-c_upper,s_lower=-s_upper;
    wire c_budget_ok=weight_s_abs<=24'd4194304&&next_c>=c_lower&&next_c<=c_upper;
    wire s_budget_ok=weight_c_abs<=24'd4194304&&next_s>=s_lower&&next_s<=s_upper;
    // 探测值向零取整，峰值511；常数除64，无额外乘法器。
    wire signed [15:0] probe_pcm=cosine_q/16'sd64;

    assign ready=enable&&(mode==M_RUN);
    assign calibrating=enable&&((mode==M_SETTLE)||(mode==M_CAL));
    assign fault=enable&&(mode==M_FAULT);

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            mode<=M_ARM; engine<=E_IDLE; phase<=32'd0; selected_tone<=2'd1; selected_increment<=32'd44667660;
            theta<=8'd0; lookup_angle<=8'd0; phase_offset<=8'd0;
            error_q<=17'sd0; sine_q<=16'sd0; cosine_q<=16'sd0;
            fsine_q<=16'sd0; fcosine_q<=16'sd0;
            weight_c<=24'sd0; weight_s<=24'sd0;
            settle_count<=14'd0; cal_count<=14'd0;
            cal_c<=48'sd0; cal_s<=48'sd0;
            norm_c<=48'sd0; norm_s<=48'sd0;
            path_c<=16'sd0; path_s<=16'sd0;
            calibration_shift<=6'd0; adaptation_scale<=3'd0;
            scan_index<=6'd0; best_phase<=8'd0;
            best_score<=40'sh8000000000; sum_product<=40'sd0;
            mul_a<=24'sd0; mul_b<=16'sd0;
            sample_out_valid<=1'b0; sample_out<=16'sd0; adaptation_done<=0;limit_reached<=0; basis_valid<=0; error_dc_q8<=0;
        end else begin
            basis_valid<=0;
            adaptation_done<=0;
            sample_out_valid<=1'b0;
            if(!enable) begin
                mode<=M_ARM; engine<=E_IDLE; phase<=32'd0;
                weight_c<=24'sd0; weight_s<=24'sd0; sample_out<=16'sd0; error_dc_q8<=0;limit_reached<=0;
            end else if(command) begin
                // ARM/FAULT按一次开始或复位；运行/校准按一次立即停止注入。
                if(mode==M_ARM) begin
                    if(override_enable&&!override_valid)mode<=M_FAULT;
                    else begin mode<=M_SETTLE;selected_tone<=tone_select;
                        selected_increment<=override_enable ? override_increment : preset_increment;
                    end
                end
                else mode<=M_ARM;
                engine<=E_IDLE; phase<=32'd0;
                weight_c<=24'sd0; weight_s<=24'sd0;
                settle_count<=14'd0; cal_count<=14'd0;limit_reached<=0;
                cal_c<=48'sd0; cal_s<=48'sd0;
                calibration_shift<=6'd0; adaptation_scale<=3'd0;
                sample_out<=16'sd0;
            end else if(sample_valid&&(engine!=E_IDLE)) begin
                mode<=M_FAULT; engine<=E_IDLE;
                sample_out<=16'sd0; sample_out_valid<=1'b1;
            end else begin
                case(engine)
                    E_IDLE: if(sample_valid) begin
                        error_q<=centered_error;
                        if(error_sample<=16'sd30000&&error_sample>= -16'sd30000)
                            error_dc_q8<=error_dc_q8+(error_dc_delta>>>10);
                        theta<=phase[31:24]; lookup_angle<=phase[31:24];
                        phase<=phase+phase_increment; engine<=E_SIN;
                        // 削顶后的误差不能用于辨识和自适应。
                        if((error_sample>16'sd30000)||(error_sample< -16'sd30000))
                            mode<=M_FAULT;
                    end
                    E_SIN: begin
                        sine_q<=lookup_value; lookup_angle<=theta+8'd64;
                        engine<=E_COS;
                    end
                    E_COS: begin
                        cosine_q<=lookup_value; lookup_angle<=theta+phase_offset;
                        engine<=E_FSIN;
                    end
                    E_FSIN: begin
                        fsine_q<=lookup_value;
                        lookup_angle<=theta+phase_offset+8'd64; engine<=E_FCOS;
                    end
                    E_FCOS: begin fcosine_q<=lookup_value; basis_valid<=mode==M_RUN; engine<=E_DISPATCH; end
                    E_DISPATCH: begin
                        if((mode==M_ARM)||(mode==M_FAULT)) begin
                            sample_out<=16'sd0; sample_out_valid<=1'b1; engine<=E_IDLE;
                        end else if(mode==M_RUN) begin
                            mul_a<=weight_c; mul_b<=cosine_q; engine<=E_YC_WAIT;
                        end else begin
                            sample_out<=probe_pcm; sample_out_valid<=1'b1;
                            if(mode==M_SETTLE) begin
                                if(settle_count==14'd8191) begin
                                    mode<=M_CAL; cal_c<=48'sd0; cal_s<=48'sd0;
                                    cal_count<=14'd0;
                                end else settle_count<=settle_count+14'd1;
                                engine<=E_IDLE;
                            end else begin
                                mul_a<={{7{error_q[16]}},error_q};
                                mul_b<=cosine_q; engine<=E_CAL_C_WAIT;
                            end
                        end
                    end
                    E_CAL_C_WAIT: engine<=E_CAL_C_GET;
                    E_CAL_C_GET: begin
                        cal_c<=cal_c+{{8{product[39]}},product};
                        mul_a<={{7{error_q[16]}},error_q};
                        mul_b<=sine_q; engine<=E_CAL_S_WAIT;
                    end
                    E_CAL_S_WAIT: engine<=E_CAL_S_GET;
                    E_CAL_S_GET: begin
                        cal_s<=cal_s_next;
                        if(cal_count==14'd9999) begin
                            if(calibration_too_weak) begin
                                mode<=M_FAULT; engine<=E_IDLE; sample_out<=16'sd0;
                            end
                            else begin norm_c<=cal_c; norm_s<=-cal_s_next; engine<=E_NORM; end
                        end else begin cal_count<=cal_count+14'd1; engine<=E_IDLE; end
                    end
                    E_NORM: begin
                        if(normalization_needed) begin
                            norm_c<=norm_c>>>1; norm_s<=norm_s>>>1;
                            calibration_shift<=calibration_shift+6'd1;
                        end else begin
                            path_c<=norm_c[15:0]; path_s<=norm_s[15:0];
                            // 分量校准幅度每四倍一档；控制有效步长，保留弱校准拒绝。
                            case(calibration_shift)
                                19:adaptation_scale<=5;20:adaptation_scale<=4;21:adaptation_scale<=3;
                                22:adaptation_scale<=2;23:adaptation_scale<=1;
                                default:adaptation_scale<=(calibration_shift<=18) ? 3'd6 : 3'd0;
                            endcase
                            scan_index<=6'd0; lookup_angle<=8'd0;
                            best_score<=40'sh8000000000; best_phase<=8'd0;
                            engine<=E_SCAN_SIN;
                        end
                    end
                    E_SCAN_SIN: begin
                        sine_q<=lookup_value;
                        lookup_angle<={scan_index,2'b00}+8'd64; engine<=E_SCAN_COS;
                    end
                    E_SCAN_COS: begin cosine_q<=lookup_value; engine<=E_SCAN_SET; end
                    E_SCAN_SET: begin
                        mul_a<={{8{path_c[15]}},path_c}; mul_b<=cosine_q;
                        engine<=E_SCAN_C_WAIT;
                    end
                    E_SCAN_C_WAIT: engine<=E_SCAN_C_GET;
                    E_SCAN_C_GET: begin
                        sum_product<=product; mul_a<={{8{path_s[15]}},path_s};
                        mul_b<=sine_q; engine<=E_SCAN_S_WAIT;
                    end
                    E_SCAN_S_WAIT: engine<=E_SCAN_S_GET;
                    E_SCAN_S_GET: begin
                        if(total_product>$signed({best_score[39],best_score})) begin
                            best_score<=total_product[39:0]; best_phase<={scan_index,2'b00};
                        end
                        if(scan_index==6'd63) begin
                            if(total_product>$signed({best_score[39],best_score}))
                                phase_offset<={scan_index,2'b00};
                            else phase_offset<=best_phase;
                            mode<=M_RUN; engine<=E_IDLE;
                        end else begin
                            scan_index<=scan_index+6'd1;
                            lookup_angle<={scan_index+6'd1,2'b00}; engine<=E_SCAN_SIN;
                        end
                    end
                    E_YC_WAIT: engine<=E_YC_GET;
                    E_YC_GET: begin
                        sum_product<=product; mul_a<=weight_s; mul_b<=sine_q; engine<=E_YS_WAIT;
                    end
                    E_YS_WAIT: engine<=E_YS_GET;
                    E_YS_GET: begin
                        sample_out_valid<=1'b1;
                        if((output_pcm>PCM_LIMIT)||(output_pcm< -PCM_LIMIT)) begin
                            sample_out<=16'sd0; mode<=M_FAULT; engine<=E_IDLE;
                        end else begin
                            sample_out<=output_pcm[15:0];
                            mul_a<=adaptation_error;
                            mul_b<=fcosine_q; engine<=E_GC_WAIT;
                        end
                    end
                    E_GC_WAIT: engine<=E_GC_GET;
                    E_GC_GET: begin
                        if((next_c>COEFF_LIMIT)||(next_c< -COEFF_LIMIT)) begin
                            weight_c<=24'sd0;
                            mode<=M_FAULT; engine<=E_IDLE; sample_out<=16'sd0;
                        end else begin
                            if(c_budget_ok)weight_c<=next_c[23:0];else limit_reached<=1;
                            mul_a<=adaptation_error;
                            mul_b<=fsine_q; engine<=E_GS_WAIT;
                        end
                    end
                    E_GS_WAIT: engine<=E_GS_GET;
                    E_GS_GET: begin
                        if((next_s>COEFF_LIMIT)||(next_s< -COEFF_LIMIT)) begin
                            weight_s<=24'sd0;
                            mode<=M_FAULT; sample_out<=16'sd0;
                        end else begin
                            if(s_budget_ok)weight_s<=next_s[23:0];else limit_reached<=1;
                            adaptation_done<=1;
                        end
                        engine<=E_IDLE;
                    end
                    default: begin mode<=M_FAULT; engine<=E_IDLE; sample_out<=16'sd0; end
                endcase
            end
        end
    end
endmodule

