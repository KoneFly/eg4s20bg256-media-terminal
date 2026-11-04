`timescale 1ns/1ps

module pcf_fft_frontend (
    input wire clk,
    input wire rst_n,
    input wire frame_start,
    input wire s_valid,
    input wire signed [15:0] s_data,
    output reg busy,
    output reg ch_valid,
    output reg [6:0] ch_index,
    output reg [7:0] ch_data,
    output reg frame_done,
    output reg debug_valid,
    output reg [11:0] debug_index,
    output reg signed [15:0] debug_re,
    output reg signed [15:0] debug_im
);
    localparam [4:0] ST_IDLE=0, ST_LOAD=1, ST_READ_A=2, ST_READ_B=3,
        ST_GET_B=4, ST_RR=5, ST_II=6, ST_RI=7, ST_IR=8,
        ST_WRITE_A=9, ST_WRITE_B=10, ST_DEBUG_PRIME=11, ST_DEBUG=12,
        ST_CH_START=13, ST_CH_READ=14, ST_CH_GET=15,
        ST_INTERP_A=16, ST_INTERP_B=17, ST_INTERP_GET=18,
        ST_INTERP_MUL=19, ST_CH_OUTPUT=20, ST_SMOOTH=21,
        ST_INIT=22, ST_LOG=23, ST_DB=24, ST_NUM=25, ST_MAP=26, ST_LOAD_FLUSH=27,
        ST_CH_MAG=28, ST_INTERP_CAPTURE=29, ST_MAP_STORE=30;
    reg [4:0] state;
    reg [11:0] sample_index, group_base, butterfly_index;
    reg [3:0] stage_index;
    reg [11:0] addr_a_reg, addr_b_reg, debug_counter, scan_index;
    reg [6:0] channel_index;
    reg signed [15:0] a_re, a_im, b_re, b_im;
    reg signed [17:0] p_rr, p_ii, p_ri, p_ir;
    reg signed [15:0] write_b_re, write_b_im;
    reg [15:0] channel_max, interp_a, interp_b;
    reg [7:0] energy_mem [0:127];
    reg [7:0] smooth_left;
    reg [10:0] init_index;
    reg signed [15:0] twiddle_re, twiddle_im;
    reg [12:0] normalized_reg;
    reg signed [16:0] log_q12_reg;
    reg signed [31:0] db_q8_reg, numerator_reg;
    reg window_pending;
    reg [11:0] window_addr;
    reg [15:0] window_data;
    reg [15:0] current_mag;
    reg [7:0] mapped_energy;

    `include "fft_tables.vh"

    function automatic [11:0] bit_reverse12(input [11:0] value);
        integer i;
        begin
            for (i=0; i<12; i=i+1) bit_reverse12[i]=value[11-i];
        end
    endfunction

    function automatic [15:0] magnitude_word(input [31:0] word);
        reg [15:0] ar, ai;
        reg [31:0] mx, mn, mag;
        begin
            ar=word[15] ? (~word[15:0]+16'd1) : word[15:0];
            ai=word[31] ? (~word[31:16]+16'd1) : word[31:16];
            mx={16'd0,(ar>ai ? ar : ai)};
            mn={16'd0,(ar>ai ? ai : ar)};
            mag=(((mx<<9)-(mx<<5))>>9)+(((mn<<9)-(mn<<5))>>10);
            magnitude_word=mag[15:0];
        end
    endfunction

    function automatic [12:0] normalize_magnitude(input [15:0] magnitude);
        integer e, value;
        begin
            value={16'd0,magnitude};
            e=0;
            if (magnitude!=0) begin
                if (value>=32768) begin e=7; value=value>>7; end
                else if (value>=16384) begin e=6; value=value>>6; end
                else if (value>=8192) begin e=5; value=value>>5; end
                else if (value>=4096) begin e=4; value=value>>4; end
                else if (value>=2048) begin e=3; value=value>>3; end
                else if (value>=1024) begin e=2; value=value>>2; end
                else if (value>=512) begin e=1; value=value>>1; end
                else if (value>=256) e=0;
                else if (value>=128) begin e=-1; value=value<<1; end
                else if (value>=64) begin e=-2; value=value<<2; end
                else if (value>=32) begin e=-3; value=value<<3; end
                else if (value>=16) begin e=-4; value=value<<4; end
                else if (value>=8) begin e=-5; value=value<<5; end
                else if (value>=4) begin e=-6; value=value<<6; end
                else if (value>=2) begin e=-7; value=value<<7; end
                else begin e=-8; value=value<<8; end
            end
            normalize_magnitude={e[4:0],value[7:0]};
        end
    endfunction

    function automatic signed [16:0] log2_q12(input [15:0] magnitude);
        reg [12:0] normalized;
        begin
            normalized=normalize_magnitude(magnitude);
            log2_q12=$signed({normalized[12:8],12'd0})+
                $signed({1'b0,fft_log_tail({1'b0,normalized[7:0]})});
        end
    endfunction

    function automatic signed [31:0] db_from_mag(input [15:0] magnitude);
        integer log_value;
        reg signed [16:0] log_fixed;
        begin
            log_fixed=log2_q12(magnitude);
            log_value={{15{log_fixed[16]}},log_fixed};
            if (magnitude==0) db_from_mag=-(1<<20);
            else db_from_mag=(((log_value<<10)+(log_value<<9)+(log_value<<2)+log_value)>>>12)-7705;
        end
    endfunction

    function automatic [7:0] map_numerator(input signed [31:0] numerator);
        reg [13:0] positive_numerator;
        reg [21:0] scaled_numerator, mapped;
        begin
            positive_numerator=0; scaled_numerator=0; mapped=0;
            if (numerator<=0) map_numerator=0;
            else if (numerator>=15360) map_numerator=255;
            else begin
                positive_numerator=numerator[13:0];
                scaled_numerator=({8'd0,positive_numerator}<<8)-{8'd0,positive_numerator};
                mapped=scaled_numerator/22'd15360;
                map_numerator=mapped[7:0];
            end
        end
    endfunction

    function automatic [7:0] energy_from_mag(input [15:0] magnitude,input signed [15:0] tilt);
        begin
            energy_from_mag=map_numerator(db_from_mag(magnitude)+$signed({{16{tilt[15]}},tilt})+32'sd18944);
        end
    endfunction

    function automatic signed [15:0] stage_scale(input signed [18:0] value);
        reg signed [18:0] scaled;
        begin
            scaled=(value+19'sd1)>>>1;
            stage_scale=scaled[15:0];
        end
    endfunction

    wire [12:0] half_span=13'd1<<stage_index;
    wire [12:0] full_span=half_span<<1;
    wire [11:0] addr_a=group_base+butterfly_index;
    wire [11:0] addr_b=addr_a+half_span[11:0];
    wire [11:0] twiddle_index=butterfly_index<<(4'd11-stage_index);
    // Runtime initialization avoids reliance on TD's ignored ERAM power-up values.
    (* ram_style="bram_32k" *) reg [15:0] sine_mem [0:1024];
    (* ram_style="bram_32k" *) reg [15:0] hann_mem [0:2047];
    reg [15:0] sine_q, hann_q;
    wire [11:0] sine_abs=twiddle_index<=12'd1024 ? twiddle_index : 12'd2048-twiddle_index;
    wire [11:0] cosine_abs=twiddle_index<=12'd1024 ? 12'd1024-twiddle_index : twiddle_index-12'd1024;
    wire [10:0] sine_raddr=state==ST_READ_A ? sine_abs[10:0] : cosine_abs[10:0];
    wire [11:0] hann_next=sample_index+((state==ST_LOAD && s_valid) ? 12'd1 : 12'd0);
    wire [11:0] hann_mirror=12'd0-hann_next;
    wire [10:0] hann_raddr=hann_next[11] ? hann_mirror[10:0] : hann_next[10:0];
    wire signed [15:0] window_q15=sample_index==12'd2048 ? 16'sd32767 :
        sample_index==12'd3072 ? 16'sd16384 : $signed(hann_q);
    always @(posedge clk) begin
        if (state==ST_INIT && rst_n) begin
            if (init_index<=11'd1024) sine_mem[init_index]<=fft_qsin_quadrant(init_index);
            hann_mem[init_index]<=fft_hann_half(init_index);
        end
        sine_q<=sine_mem[sine_raddr];
        hann_q<=hann_mem[hann_raddr];
    end
    wire [11:0] channel_lo=fft_map_lo(channel_index);
    wire [11:0] channel_hi=fft_map_hi(channel_index);
    wire [23:0] channel_cen=fft_map_cen(channel_index);
    wire signed [15:0] channel_tilt=fft_map_tilt(channel_index);
    wire [11:0] interp_bin=channel_cen[19:8];
    wire [7:0] interp_fraction=channel_cen[7:0];
    wire signed [18:0] tr={{1{p_rr[17]}},p_rr}-{{1{p_ii[17]}},p_ii};
    wire signed [18:0] ti={{1{p_ri[17]}},p_ri}+{{1{p_ir[17]}},p_ir};
    wire signed [18:0] ar_ext={{3{a_re[15]}},a_re};
    wire signed [18:0] ai_ext={{3{a_im[15]}},a_im};

    // One signed multiplier serves loading, all four Q15 products and interpolation.
    reg signed [17:0] mul_lhs, mul_rhs;
    wire signed [35:0] mul_product=mul_lhs*mul_rhs;
    wire signed [35:0] q15_rounded=(mul_product+36'sd16384)>>>15;
    wire signed [17:0] interp_delta=$signed({2'b00,interp_b})-$signed({2'b00,interp_a});
    wire signed [35:0] interp_value=$signed({20'd0,interp_a})+(mul_product>>>8);
    always @* begin
        mul_lhs=18'sd0;
        mul_rhs=18'sd0;
        case (state)
            ST_LOAD: begin
                mul_lhs={{2{s_data[15]}},s_data[15:4],4'b0000};
                mul_rhs={{2{window_q15[15]}},window_q15};
            end
            ST_RR: begin mul_lhs={{2{b_re[15]}},b_re}; mul_rhs={{2{twiddle_re[15]}},twiddle_re}; end
            ST_II: begin mul_lhs={{2{b_im[15]}},b_im}; mul_rhs={{2{twiddle_im[15]}},twiddle_im}; end
            ST_RI: begin mul_lhs={{2{b_re[15]}},b_re}; mul_rhs={{2{twiddle_im[15]}},twiddle_im}; end
            ST_IR: begin mul_lhs={{2{b_im[15]}},b_im}; mul_rhs={{2{twiddle_re[15]}},twiddle_re}; end
            ST_INTERP_MUL: begin mul_lhs=interp_delta; mul_rhs=$signed({10'd0,interp_fraction}); end
            ST_DB: begin mul_lhs={{1{log_q12_reg[16]}},log_q12_reg}; mul_rhs=18'sd1541; end
            default: begin end
        endcase
    end

    // Every frame-memory access uses this one synchronous read and one write port.
    reg frame_we;
    reg [11:0] frame_waddr, frame_raddr;
    reg [31:0] frame_din;
    wire [31:0] frame_q;
    pcf_fft_frame_ram u_frame (.clk(clk), .we(frame_we), .waddr(frame_waddr),
        .din(frame_din), .raddr(frame_raddr), .q(frame_q));
    always @(posedge clk) current_mag<=magnitude_word(frame_q);
    always @* begin
        frame_we=1'b0;
        frame_waddr=12'd0;
        frame_din=32'd0;
        frame_raddr=12'd0;
        case (state)
            ST_LOAD: begin
                // Window writes are supplied by the one-cycle pending register below.
            end
            ST_READ_A: frame_raddr=addr_a;
            ST_READ_B: frame_raddr=addr_b_reg;
            ST_WRITE_A: begin
                frame_we=rst_n;
                frame_waddr=addr_a_reg;
                frame_din={stage_scale(ai_ext+ti),stage_scale(ar_ext+tr)};
            end
            ST_WRITE_B: begin
                frame_we=rst_n;
                frame_waddr=addr_b_reg;
                frame_din={write_b_im,write_b_re};
            end
            ST_DEBUG_PRIME: frame_raddr=12'd0;
            ST_DEBUG: frame_raddr=debug_counter+12'd1;
            ST_CH_READ: frame_raddr=scan_index;
            ST_INTERP_A: frame_raddr=interp_bin;
            ST_INTERP_B: frame_raddr=interp_bin+12'd1;
            default: begin end
        endcase
        if (window_pending) begin
            frame_we=rst_n;
            frame_waddr=window_addr;
            frame_din={16'd0,window_data};
        end
    end

    wire [7:0] smooth_right=energy_mem[channel_index==7'd127 ? 7'd127 : channel_index+7'd1];
    wire [7:0] smooth_prev=channel_index==0 ? energy_mem[0] : smooth_left;
    wire [9:0] smooth_sum={2'd0,smooth_prev}+{1'd0,energy_mem[channel_index],1'b0}+{2'd0,smooth_right};
    wire [7:0] smooth_value=smooth_sum[9:2];

    always @(posedge clk) begin
        if (!rst_n) begin
            state<=ST_INIT; busy<=1; ch_valid<=0; frame_done<=0; debug_valid<=0;
            ch_index<=0; ch_data<=0; debug_index<=0; debug_re<=0; debug_im<=0;
            sample_index<=0; group_base<=0; butterfly_index<=0; stage_index<=0;
            addr_a_reg<=0; addr_b_reg<=0; debug_counter<=0; scan_index<=0;
            channel_index<=0; a_re<=0; a_im<=0; b_re<=0; b_im<=0;
            p_rr<=0; p_ii<=0; p_ri<=0; p_ir<=0; write_b_re<=0; write_b_im<=0;
            channel_max<=0; interp_a<=0; interp_b<=0; smooth_left<=0;
            init_index<=0; twiddle_re<=0; twiddle_im<=0;
            normalized_reg<=0; log_q12_reg<=0; db_q8_reg<=0; numerator_reg<=0;
            window_pending<=0; window_addr<=0; window_data<=0;
            mapped_energy<=0;
        end else begin
            ch_valid<=0; frame_done<=0; debug_valid<=0;
            window_pending<=0;
            case (state)
                ST_INIT: begin
                    busy<=1;
                    if (init_index==11'd2047) begin state<=ST_IDLE; busy<=0; end
                    else init_index<=init_index+11'd1;
                end
                ST_IDLE: begin
                    busy<=0;
                    if (frame_start) begin busy<=1; sample_index<=0; state<=ST_LOAD; end
                end
                ST_LOAD: if (s_valid) begin
                    window_pending<=1;
                    window_addr<=bit_reverse12(sample_index);
                    window_data<=q15_rounded[15:0];
                    if (sample_index==4095) begin
                        stage_index<=0; group_base<=0; butterfly_index<=0; state<=ST_LOAD_FLUSH;
                    end else sample_index<=sample_index+12'd1;
                end
                ST_LOAD_FLUSH: state<=ST_READ_A;
                ST_READ_A: begin addr_a_reg<=addr_a; addr_b_reg<=addr_b; state<=ST_READ_B; end
                ST_READ_B: begin
                    a_re<=$signed(frame_q[15:0]); a_im<=$signed(frame_q[31:16]);
                    twiddle_im<=-$signed(sine_q); state<=ST_GET_B;
                end
                ST_GET_B: begin
                    b_re<=$signed(frame_q[15:0]); b_im<=$signed(frame_q[31:16]);
                    twiddle_re<=twiddle_index>12'd1024 ? -$signed(sine_q) : $signed(sine_q);
                    state<=ST_RR;
                end
                ST_RR: begin p_rr<=q15_rounded[17:0]; state<=ST_II; end
                ST_II: begin p_ii<=q15_rounded[17:0]; state<=ST_RI; end
                ST_RI: begin p_ri<=q15_rounded[17:0]; state<=ST_IR; end
                ST_IR: begin p_ir<=q15_rounded[17:0]; state<=ST_WRITE_A; end
                ST_WRITE_A: begin
                    write_b_re<=stage_scale(ar_ext-tr); write_b_im<=stage_scale(ai_ext-ti); state<=ST_WRITE_B;
                end
                ST_WRITE_B: begin
                    if ({1'b0,butterfly_index}==half_span-13'd1) begin
                        butterfly_index<=0;
                        if ({1'b0,group_base}+full_span==13'd4096) begin
                            group_base<=0;
                            if (stage_index==11) begin debug_counter<=0; state<=ST_DEBUG_PRIME; end
                            else begin stage_index<=stage_index+4'd1; state<=ST_READ_A; end
                        end else begin group_base<=group_base+full_span[11:0]; state<=ST_READ_A; end
                    end else begin butterfly_index<=butterfly_index+12'd1; state<=ST_READ_A; end
                end
                ST_DEBUG_PRIME: state<=ST_DEBUG;
                ST_DEBUG: begin
                    debug_valid<=1; debug_index<=debug_counter;
                    debug_re<=$signed(frame_q[15:0]); debug_im<=$signed(frame_q[31:16]);
                    if (debug_counter==4095) begin channel_index<=0; state<=ST_CH_START; end
                    else debug_counter<=debug_counter+12'd1;
                end
                ST_CH_START: begin
                    if (channel_lo<=channel_hi) begin scan_index<=channel_lo; channel_max<=0; state<=ST_CH_READ; end
                    else state<=ST_INTERP_A;
                end
                ST_CH_READ: state<=ST_CH_MAG;
                ST_CH_MAG: state<=ST_CH_GET;
                ST_CH_GET: begin
                    if (current_mag>channel_max) channel_max<=current_mag;
                    if (scan_index==channel_hi) state<=ST_CH_OUTPUT;
                    else begin scan_index<=scan_index+12'd1; state<=ST_CH_READ; end
                end
                ST_INTERP_A: state<=ST_INTERP_B;
                ST_INTERP_B: state<=ST_INTERP_GET;
                ST_INTERP_GET: begin interp_a<=current_mag; state<=ST_INTERP_CAPTURE; end
                ST_INTERP_CAPTURE: begin interp_b<=current_mag; state<=ST_INTERP_MUL; end
                ST_INTERP_MUL: begin channel_max<=interp_value[15:0]; state<=ST_CH_OUTPUT; end
                ST_CH_OUTPUT: begin
                    normalized_reg<=normalize_magnitude(channel_max); state<=ST_LOG;
                end
                ST_LOG: begin
                    log_q12_reg<=$signed({normalized_reg[12:8],12'd0})+
                        $signed({1'b0,fft_log_tail({1'b0,normalized_reg[7:0]})});
                    state<=ST_DB;
                end
                ST_DB: begin
                    db_q8_reg<=channel_max==0 ? -(32'sd1<<20) :
                        $signed({{8{mul_product[35]}},mul_product[35:12]})-32'sd7705;
                    state<=ST_NUM;
                end
                ST_NUM: begin
                    numerator_reg<=db_q8_reg+$signed({{16{channel_tilt[15]}},channel_tilt})+32'sd18944;
                    state<=ST_MAP;
                end
                ST_MAP: begin
                    mapped_energy<=map_numerator(numerator_reg); state<=ST_MAP_STORE;
                end
                ST_MAP_STORE: begin
                    energy_mem[channel_index]<=mapped_energy;
                    if (channel_index==127) begin channel_index<=0; state<=ST_SMOOTH; end
                    else begin channel_index<=channel_index+7'd1; state<=ST_CH_START; end
                end
                ST_SMOOTH: begin
                    smooth_left<=smooth_value;
                    ch_valid<=1; ch_index<=channel_index; ch_data<=smooth_value;
                    if (channel_index==127) begin frame_done<=1; busy<=0; state<=ST_IDLE; end
                    else channel_index<=channel_index+7'd1;
                end
                default: begin state<=ST_IDLE; busy<=0; end
            endcase
        end
    end
endmodule

module pcf_fft_frame_ram (
    input wire clk, input wire we, input wire [11:0] waddr,
    input wire [31:0] din, input wire [11:0] raddr, output reg [31:0] q
);
    (* ram_style="bram_32k" *) reg [31:0] mem [0:4095];
    always @(posedge clk) begin
        if (we) mem[waddr]<=din;
        q<=mem[raddr];
    end
endmodule
