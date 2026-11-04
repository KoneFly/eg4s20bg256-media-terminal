// 多周期状态更新；共享词 RAM、亮度减法器、DSP 与读/改/写记录缓冲。
module pcb_frame_updater (
    input wire clk, rst_n, frame_tick,
    input wire [1023:0] spec_frame,
    input wire cfg_wr_en,
    input wire [5:0] cfg_wr_addr,
    input wire [15:0] cfg_wr_data,
    input wire snapshot_ack_toggle,
    output reg state_wr_en, state_wr_sel,
    output reg [7:0] state_wr_addr,
    output reg [31:0] state_wr_data,
    output reg [1:0] state_wr_lane,
    output reg state_commit_toggle,
    output wire frame_ready,
    output reg frame_accept, frame_done, busy, err_valid,
    output reg [3:0] err_code
);
`include "pcb_dynamic_roms_w2.vh"

    localparam INIT=0, IDLE=1, AGG=2, BAND=3, BEAT=4, RC_EMIT=5, RC_MOVE=6,
      TR_REQ=7, BUS_R_REQ=8, TR_CAP=9, DIVIDE=10, DURATION=11, GROW=12,
      WAIT_MUL=13, GROW_CAP=14, FLOW=15, PULSE_ALLOC=16, PULSE_STEP=17,
      PULSE_NODE=18, PULSE_HIT=19, PULSE_SAVE=20, TR_SAVE=21,
      COMP_REQ=22, COMP_CAP=23, NODE_REQ=24, NODE_CAP=25,
      BAR_REQ=26, BAR_CAP=27, BUS_R_WAIT=28, BUS_R_TAKE=29,
      BUS_W=30, BUS_DRAIN=31, NODE_GROW=32, AGG_REQ=33, INIT_DONE=34,
      T1_REQ=49, T1_CAP=50, T1_WRITE=51, T2_REQ=52, T2_EVEN=53,
      T2_ODD=54, T2_WRITE=55, DRAIN=59, COMMIT=60,
      TR_START=61, TR_DIV_PREP=62, DURATION_CAP=63,
      FLOW_RF=64, FLOW_GAIN=65, FLOW_PHASE=66,
      RF_PREP=67, RF_DELTA=68, RF_SET=69, RF_VALUE=70, RF_RESULT=71,
      NODE_TARGET=72, NODE_HUB_TARGET=73, NODE_SCALE=74, NODE_RF=75, NODE_SAVE=76,
      BAR_HEIGHT=77, BAR_PEAK=78, BAR_SAVE=79,
      PULSE_LEFT=80, PULSE_RIGHT=81, PULSE_PICK=82, PULSE_WRITE=83, PULSE_FINALIZE=84,
      BAND_DECIDE=85, BAND_ONSET=86, BAND_AVG_PREP=87, BAND_AVG_APPLY=88,
      BEAT_SCAN=89, BEAT_DONE=90, RC_PICK=91, RC_WRITE=92;
    reg [6:0] state, bus_return, mul_return, div_return, rf_return;
    reg ack_meta, ack_sync;
    reg [1023:0] spectrum;
    reg [15:0] cfg [0:7], active_cfg [0:7];
    reg [7:0] bands [0:7], onset [0:7], cooldown [0:7];
    // flux 是 16 路正差之和，最大 4080；平均值递推始终位于旧平均与 flux 之间。
    reg [11:0] flux_average [0:7];
    reg [7:0] beat_k, lo_on, chip_ink, comp_fade [0:19];
    reg [9:0] comet_pos [0:3];
    reg signed [1:0] comet_dir [0:3];
    reg [7:0] comet_amp [0:3];
    reg [31:0] frame_number;
    // 统一词地址：trace 0..1023，startF 1024..1151，node 1152..1407，
    // bar 1408..1663，prev 1664..1727；其余保留，运行时整 bank 清零。
    reg [10:0] ram_addr, init_count, bus_addr;
    wire [15:0] ram_q;
    reg [15:0] ram_wdata, previous_pair;
    reg ram_we;
    reg [3:0] bus_word, bus_length;
    reg [2:0] bus_kind;
    reg [6:0] bus_record;
    reg [31:0] bus_wdata;
    localparam LOAD_TRACE=0, LOAD_NODE=1, LOAD_BAR=2, LOAD_PREV=3, LOAD_GROW=4;
    reg [127:0] trace_work;
    reg signed [15:0] start_rdata, start_work;
    reg [31:0] record_rdata;
    pcb_ram_2k16 state_bank(clk,ram_we,ram_addr,ram_addr,ram_wdata,ram_q);
    // 所有操作数非负：a 最大 127*16，b 最大 256，完整乘积保留 20bit。
    reg [10:0] mul_a;
    reg [8:0] mul_b;
    reg [19:0] mul_product;
    wire signed [31:0] mul_result={12'd0,mul_product};
    always @(posedge clk) mul_product<=mul_a*mul_b;
    reg [15:0] div_num, div_den, div_rem, div_quot;
    reg [3:0] div_bit;
    wire [16:0] div_trial = {div_rem, div_num[div_bit]};

    reg [7:0] i;
    reg [1:0] j, q, rc;
    reg [6:0] k, strongest;
    reg emit_dir;
    reg [11:0] sum_spec, flux;
    reg [7:0] max_spec, strongest_value;
    integer a, b, c;
    reg [1:0] slot;
    reg [15:0] pos_old, pos_new;
    reg [7:0] pulse_amp;
    reg [31:0] pulse_word;
    reg [15:0] even_word;
    reg [27:0] trace_meta;
    reg [26:0] node_meta;
    reg [13:0] pulse_node_meta;
    wire [27:0] trace_lookup = trace_rom(state==INIT ? init_count[6:0] : i[6:0]);
    wire [27:0] init_meta = trace_lookup;
    wire [26:0] node_lookup = node_rom(i[6:0]);
    wire [13:0] trace_node_meta = trace_node_rom({i[6:0], q[0]});
    wire [13:0] comp_meta = comp_rom(i[4:0]);
    wire [31:0] pulse_entry = j==0 ? trace_work[63:32] : j==1 ? trace_work[95:64] : trace_work[127:96];
    reg [6:0] spec_index;
    reg [7:0] spec_value;
    // 先锁存对象的谱索引，再独立注册 128:1 谱选择结果；不与算术链串联。
    always @(posedge clk) spec_value <= spectrum[{spec_index,3'd0}+:8];
    reg [8:0] pair_sum, rf_a, rf_b, rf_calc;
    reg [7:0] rf_current, rf_target, rf_result;
    reg [1:0] rf_drop;
    reg rf_rise;
    reg [7:0] node_vis, node_b, node_hub, node_target;
    reg [7:0] bar_height, bar_peak, bar_hold;
    reg [7:0] pulse_level, pulse_peak, pulse_age;
    reg [16:0] pulse_position;
    reg [12:0] band_threshold, onset_delta;
    reg [15:0] duration;
    reg [11:0] average_current;
    reg [31:0] elapsed;
    reg signed [12:0] flux_difference;
    reg [2:0] beat_scan;
    reg [7:0] beat_max, beat_decay;
    reg [1:0] comet_candidate, comet_scan;
    wire unused_meta_bits = ^{init_meta[27:26],init_meta[16:0],pair_sum[0],node_meta[6:0],flux_difference[2:0],trace_meta[13:7]};
    assign frame_ready = !busy && ack_sync == state_commit_toggle;

    function integer max2;
        input integer x, y;
        begin max2 = x > y ? x : y; end
    endfunction
    // 共享配置限幅；各参数仅保留规格范围所需位宽，高位显式补零。
    reg [6:0] cfg_low;
    reg [9:0] cfg_high;
    always @* begin
        case(cfg_wr_addr[2:0])
        0:begin cfg_low=30;cfg_high=200;end
        1:begin cfg_low=12;cfg_high=90;end
        2:begin cfg_low=0;cfg_high=30;end
        3:begin cfg_low=0;cfg_high=32;end
        4:begin cfg_low=0;cfg_high=64;end
        5:begin cfg_low=16;cfg_high=96;end
        6:begin cfg_low=64;cfg_high=512;end
        default:begin cfg_low=8;cfg_high=64;end
        endcase
    end
    wire [9:0] cfg_limited=cfg_wr_data<{9'd0,cfg_low} ? {3'd0,cfg_low} :
        (|cfg_wr_data[15:10] || cfg_wr_data[9:0]>cfg_high ? cfg_high : cfg_wr_data[9:0]);
    function integer signed16;
        input [15:0] x;
        begin signed16={{16{x[15]}},x};end
    endfunction
    function [7:0] max8;
        input [7:0] x, y;
        begin max8=x>y ? x : y;end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            ack_meta<=0; ack_sync<=0;
        end else begin ack_meta<=snapshot_ack_toggle; ack_sync<=ack_meta; end
    end
    // 多周期步骤保留逐位舍入；同构亮度更新共用一个 9bit 减法器。
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=INIT; busy<=1; frame_accept<=0; frame_done<=0;
            state_commit_toggle<=0; state_wr_en<=0;
            state_wr_sel<=0; state_wr_addr<=0; state_wr_lane<=0; state_wr_data<=0;
            err_valid<=0; err_code<=0;
            ram_we<=0;ram_addr<=0;ram_wdata<=0;init_count<=0;previous_pair<=0;
            bus_addr<=0;bus_word<=0;bus_length<=0;bus_kind<=0;bus_record<=0;bus_wdata<=0;
            start_rdata<=0;record_rdata<=0;
            mul_a<=0; mul_b<=0; div_num<=0; div_den<=1; div_rem<=0; div_quot<=0; div_bit<=0;
            bus_return<=IDLE; mul_return<=IDLE; div_return<=IDLE;
            i<=0; j<=0; q<=0; k<=0; rc<=0; emit_dir<=0;
            sum_spec<=0; max_spec<=0; flux<=0; strongest<=0;strongest_value<=0;
            frame_number<=0; beat_k<=0; lo_on<=0; chip_ink<=0;
            trace_work<=0; start_work<=0;
            pos_old<=0; pos_new<=0; pulse_amp<=0; pulse_word<=0;
            even_word<=0;trace_meta<=0;node_meta<=0;pulse_node_meta<=0;spec_index<=0;
            pair_sum<=0;rf_a<=0;rf_b<=0;rf_calc<=0;rf_current<=0;rf_target<=0;rf_result<=0;rf_drop<=2;rf_rise<=0;rf_return<=IDLE;
            node_vis<=0;node_b<=0;node_hub<=0;node_target<=0;
            bar_height<=0;bar_peak<=0;bar_hold<=0;pulse_level<=0;pulse_peak<=0;pulse_age<=0;pulse_position<=0;slot<=0;
            band_threshold<=0;onset_delta<=0;duration<=0;average_current<=0;elapsed<=0;flux_difference<=0;
            beat_scan<=0;beat_max<=0;beat_decay<=0;comet_candidate<=0;comet_scan<=0;
            cfg[0]<=70;cfg[1]<=36;cfg[2]<=9;cfg[3]<=8;cfg[4]<=24;cfg[5]<=44;
            cfg[6]<=160;cfg[7]<=18;
            for(a=0;a<8;a=a+1) active_cfg[a]<=0;
            for(a=0;a<8;a=a+1) begin bands[a]<=0;onset[a]<=0;cooldown[a]<=0;flux_average[a]<=0;end
            for(a=0;a<20;a=a+1) comp_fade[a]<=0;
            for(a=0;a<4;a=a+1) begin comet_pos[a]<=0;comet_dir[a]<=0;comet_amp[a]<=0;end
            spectrum<=0;
        end else begin
            state_wr_en<=0; frame_accept<=0; frame_done<=0;ram_we<=0;
            if(frame_tick && !frame_ready) begin err_valid<=1;err_code<=1;end
            if(cfg_wr_en) begin
                case(cfg_wr_addr)
                0:cfg[0]<={8'd0,cfg_limited[7:0]};
                1:cfg[1]<={9'd0,cfg_limited[6:0]};
                2:cfg[2]<={11'd0,cfg_limited[4:0]};
                3:cfg[3]<={10'd0,cfg_limited[5:0]};
                4:cfg[4]<={9'd0,cfg_limited[6:0]};
                5:cfg[5]<={9'd0,cfg_limited[6:0]};
                6:cfg[6]<={6'd0,cfg_limited};
                7:cfg[7]<={9'd0,cfg_limited[6:0]};
                default:begin end
                endcase
            end
            case(state)
            INIT: begin
                ram_we<=1;ram_addr<=init_count;ram_wdata<=0;
                if(init_count[10:7]==4'd8) ram_wdata<=init_meta[25:21]==0 ? 16'd24+({12'd0,init_meta[20:17]}<<3)+{12'd0,init_meta[20:17]} : 16'hffff;
                if(init_count==2047) state<=INIT_DONE;else init_count<=init_count+11'd1;
            end
            INIT_DONE:begin state<=IDLE;busy<=0;end
            IDLE: if(frame_tick && frame_ready) begin
                spectrum<=spec_frame;frame_accept<=1;busy<=1;frame_number<=frame_number+1;
                for(a=0;a<8;a=a+1) active_cfg[a]<=cfg[a];
                i<=0;k<=0;sum_spec<=0;max_spec<=0;flux<=0;strongest<=0;strongest_value<=0;state<=AGG_REQ;
                chip_ink<=frame_number>=23 ? 8'd255 : chip_rom(frame_number[4:0]+5'd1);
            end
            AGG_REQ:begin spec_index<=k;bus_addr<=11'd1664+{5'd0,k[6:1]};bus_word<=0;bus_length<=1;bus_kind<=LOAD_PREV;bus_return<=AGG;state<=BUS_R_REQ;end
            AGG: begin
                a={24'd0,spec_value};b=k[0] ? {24'd0,previous_pair[15:8]} : {24'd0,previous_pair[7:0]};
                sum_spec<=sum_spec+{4'd0,spec_value};max_spec<=spec_value>max_spec ? spec_value : max_spec;
                c=a-b;flux<=flux+(c>0 ? c[11:0] : 12'd0);
                bus_wdata<={16'd0,(k[0] ? {spec_value,previous_pair[7:0]} : {previous_pair[15:8],spec_value})};
                bus_addr<=11'd1664+{5'd0,k[6:1]};bus_word<=0;bus_length<=1;bus_kind<=LOAD_PREV;state<=BUS_W;
                if(spec_value>strongest_value)begin strongest<=k;strongest_value<=spec_value;end
                if(k[3:0]==15) bus_return<=BAND; else begin k<=k+7'd1;bus_return<=AGG_REQ;end
            end
            BAND: begin
                pair_sum<={1'b0,sum_spec[11:4]}+{1'b0,max_spec};
                average_current<=flux_average[i[2:0]];
                band_threshold<={1'b0,flux_average[i[2:0]]}+{2'd0,flux_average[i[2:0]][11:1]}+{3'd0,active_cfg[6][9:0]};
                state<=BAND_DECIDE;
            end
            BAND_DECIDE:begin
                bands[i[2:0]]<=pair_sum[8:1];onset[i[2:0]]<=0;
                if(cooldown[i[2:0]]!=0)begin cooldown[i[2:0]]<=cooldown[i[2:0]]-8'd1;state<=BAND_AVG_PREP;end
                else if({1'b0,flux}>band_threshold)begin onset_delta<={1'b0,flux}-band_threshold;state<=BAND_ONSET;end
                else state<=BAND_AVG_PREP;
            end
            BAND_ONSET:begin
                onset[i[2:0]]<=onset_delta>=13'd580 ? 8'd255 : 8'd110+onset_delta[9:2];
                cooldown[i[2:0]]<=7;state<=BAND_AVG_PREP;
            end
            BAND_AVG_PREP:begin
                flux_difference<=$signed({1'b0,flux})-$signed({1'b0,average_current});state<=BAND_AVG_APPLY;
            end
            BAND_AVG_APPLY:begin
                flux_average[i[2:0]]<=average_current+{{2{flux_difference[12]}},flux_difference[12:3]};
                if(i==7)state<=BEAT;else begin i<=i+8'd1;k<=k+7'd1;sum_spec<=0;max_spec<=0;flux<=0;state<=AGG_REQ;end
            end
            BEAT:begin
                beat_scan<=0;beat_max<=0;lo_on<=max8(onset[0],onset[1]);
                beat_decay<=beat_k==0 ? 8'd0 : beat_k-(beat_k>>3)-8'd1;state<=BEAT_SCAN;
            end
            BEAT_SCAN:begin
                beat_max<=max8(beat_max,onset[beat_scan]);
                if(beat_scan==7)state<=BEAT_DONE;else beat_scan<=beat_scan+3'd1;
            end
            BEAT_DONE:begin
                beat_k<=max8(beat_max,beat_decay);rc<=0;emit_dir<=0;state<=lo_on>=60 ? RC_EMIT : RC_MOVE;
            end
            RC_EMIT:begin comet_candidate<=0;comet_scan<=1;state<=RC_PICK;end
            RC_PICK:begin
                if(comet_amp[comet_scan]<comet_amp[comet_candidate])comet_candidate<=comet_scan;
                if(comet_scan==3)state<=RC_WRITE;else comet_scan<=comet_scan+2'd1;
            end
            RC_WRITE:begin
                comet_pos[comet_candidate]<={strongest,3'b100};
                comet_dir[comet_candidate]<=emit_dir==0 ? 2'sd1 : -2'sd1;
                comet_amp[comet_candidate]<=lo_on>=195 ? 8'd255 : lo_on+8'd60;
                if(emit_dir==1)begin rc<=0;state<=RC_MOVE;end else begin emit_dir<=1;state<=RC_EMIT;end
            end
            RC_MOVE: begin
                if(comet_amp[rc]!=0) begin
                    b={{30{comet_dir[rc][1]}},comet_dir[rc]};c={22'd0,comet_pos[rc]}+(b<<3)+b;comet_pos[rc]<=c[9:0];
                    comet_amp[rc]<=comet_amp[rc]-(comet_amp[rc]>>5)-8'd1;
                end
                if(rc==3) begin i<=0;state<=TR_REQ;end else rc<=rc+1;
            end
            BUS_R_REQ:begin ram_addr<=bus_addr;state<=BUS_R_WAIT;end
            BUS_R_WAIT:state<=BUS_R_TAKE;
            BUS_R_TAKE:begin
                case(bus_kind)
                LOAD_TRACE:if(bus_word==8)start_rdata<=ram_q;else trace_work<={ram_q,trace_work[127:16]};
                LOAD_NODE,LOAD_BAR:record_rdata<={ram_q,record_rdata[31:16]};
                LOAD_PREV:previous_pair<=ram_q;
                default:trace_work[15:0]<=ram_q;
                endcase
                if(bus_word+4'd1==bus_length)state<=bus_return;
                else begin bus_word<=bus_word+4'd1;bus_addr<=bus_kind==LOAD_TRACE && bus_word==7 ? 11'd1024+{4'd0,bus_record} : bus_addr+11'd1;state<=BUS_R_REQ;end
            end
            BUS_W:begin
                ram_we<=1;ram_addr<=bus_addr;
                if(bus_kind==LOAD_TRACE)begin
                    ram_wdata<=bus_word==8 ? start_work : trace_work[15:0];
                    if(bus_word!=8)trace_work<=trace_work>>16;
                end else begin ram_wdata<=bus_wdata[15:0];bus_wdata<=bus_wdata>>16;end
                if(bus_word+4'd1==bus_length)state<=BUS_DRAIN;
                else begin bus_word<=bus_word+4'd1;bus_addr<=bus_kind==LOAD_TRACE && bus_word==7 ? 11'd1024+{4'd0,bus_record} : bus_addr+11'd1;end
            end
            BUS_DRAIN:state<=bus_return;
            WAIT_MUL: state<=mul_return;
            DIVIDE: begin
                if(div_trial>={1'b0,div_den}) begin div_rem<=div_trial[15:0]-div_den;div_quot[div_bit]<=1;end
                else begin div_rem<=div_trial[15:0];div_quot[div_bit]<=0;end
                if(div_bit==0) state<=div_return;else div_bit<=div_bit-4'd1;
            end
            TR_REQ: begin
                trace_meta<=trace_lookup;spec_index<=trace_lookup[13:7];
                bus_addr<={1'd0,i[6:0],3'd0};bus_word<=0;bus_length<=9;bus_kind<=LOAD_TRACE;bus_record<=i[6:0];bus_return<=TR_CAP;state<=BUS_R_REQ;
            end
            TR_CAP: begin
                start_work<=start_rdata<0 && comp_fade[trace_meta[25:21]-5'd1]!=0 ? frame_number[15:0] : start_rdata;
                if(trace_meta[25:21]==0 && trace_work[15:0]==0)begin
                    mul_a<={7'd0,trace_meta[20:17]};mul_b<={1'b0,active_cfg[2][7:0]};mul_return<=TR_START;state<=WAIT_MUL;
                end else state<=TR_DIV_PREP;
            end
            TR_START:begin start_work<=16'd24+mul_result[15:0];state<=TR_DIV_PREP;end
            TR_DIV_PREP:begin
                div_num<=({9'd0,trace_meta[6:0]}<<6)-({9'd0,trace_meta[6:0]}<<2)+(active_cfg[0]>>1);
                div_den<=active_cfg[0];div_rem<=0;div_quot<=0;div_bit<=15;div_return<=DURATION;state<=DIVIDE;
            end
            DURATION: begin
                duration<=div_quot>active_cfg[1] ? div_quot : active_cfg[1];
                elapsed<=frame_number-signed16(start_work);
                if(start_work<0 || frame_number<=signed16(start_work) || trace_work[15:0]>={5'd0,trace_meta[6:0],4'd0})state<=FLOW;
                else state<=DURATION_CAP;
            end
            DURATION_CAP:begin
                if(elapsed>={16'd0,duration})begin trace_work[15:0]<={5'd0,trace_meta[6:0],4'd0};state<=FLOW;end
                else begin div_num<={elapsed[7:0],8'd0};div_den<=duration;div_rem<=0;div_quot<=0;div_bit<=15;div_return<=GROW;state<=DIVIDE;end
            end
            GROW: begin mul_a<={trace_meta[6:0],4'd0};mul_b<=smooth_phase_rom(div_quot[7:0]);mul_return<=GROW_CAP;state<=WAIT_MUL;end
            GROW_CAP: begin a=max2({16'd0,trace_work[15:0]},mul_result>>>8);trace_work[15:0]<=a[15:0];state<=FLOW;end
            FLOW:begin pair_sum<={1'b0,spec_value}+{1'b0,bands[trace_meta[16:14]]};state<=FLOW_RF;end
            FLOW_RF:begin rf_current<=trace_work[23:16];rf_target<=pair_sum[8:1];rf_drop<=2;rf_return<=FLOW_GAIN;state<=RF_PREP;end
            FLOW_GAIN:begin
                trace_work[23:16]<=rf_result;mul_a<={3'd0,rf_result};mul_b<={1'b0,active_cfg[4][7:0]};mul_return<=FLOW_PHASE;state<=WAIT_MUL;
            end
            FLOW_PHASE:begin trace_work[31:24]<=trace_work[31:24]+active_cfg[3][7:0]+mul_result[15:8];state<=PULSE_ALLOC;end
            // rise 等价于 target-floor((target-current)/4)，fall 仍保留原 max/负值钳位。
            RF_PREP:begin
                rf_rise<=rf_target>rf_current;
                rf_a<=rf_target>rf_current ? {1'b0,rf_target} : {5'd0,rf_current[7:4]};
                rf_b<=rf_target>rf_current ? {1'b0,rf_current} : (rf_drop==3 ? 9'h1fd : 9'h1fe);
                state<=RF_DELTA;
            end
            RF_DELTA,RF_VALUE:begin rf_calc<=rf_a-rf_b;state<=state==RF_DELTA ? RF_SET : RF_RESULT;end
            RF_SET:begin
                rf_a<=rf_rise ? {1'b0,rf_target} : {1'b0,rf_current};
                rf_b<=rf_rise ? {3'd0,rf_calc[7:2]} : rf_calc;state<=RF_VALUE;
            end
            RF_RESULT:begin
                rf_result<=!rf_rise && (rf_calc[8] || rf_calc[7:0]<rf_target) ? rf_target : rf_calc[7:0];state<=rf_return;
            end
            PULSE_ALLOC:begin pulse_level<=onset[trace_meta[16:14]];state<=PULSE_LEFT;end
            PULSE_LEFT:begin
                if(trace_meta[16:14]>0)pulse_level<=max8(pulse_level,onset[trace_meta[16:14]-3'd1]>>1);state<=PULSE_RIGHT;
            end
            PULSE_RIGHT:begin
                if(trace_meta[16:14]<7)pulse_level<=max8(pulse_level,onset[trace_meta[16:14]+3'd1]>>1);
                mul_a<={3'd0,lo_on};mul_b<=9'd140;mul_return<=PULSE_PICK;state<=WAIT_MUL;
            end
            PULSE_PICK:begin
                pulse_level<=max8(pulse_level,mul_result[15:8]);
                if(trace_work[55:48]==0)slot<=0;
                else if(trace_work[87:80]==0)slot<=1;
                else if(trace_work[119:112]==0)slot<=2;
                else if(trace_work[79:64]>trace_work[47:32])slot<=trace_work[111:96]>trace_work[79:64] ? 2'd2 : 2'd1;
                else slot<=trace_work[111:96]>trace_work[47:32] ? 2'd2 : 2'd0;
                state<=PULSE_WRITE;
            end
            PULSE_WRITE:begin
                if(trace_work[15:4]>={4'd0,active_cfg[7][7:0]} && pulse_level>=60)begin
                    case(slot)
                    0:trace_work[63:32]<={8'd0,pulse_level,16'd0};
                    1:trace_work[95:64]<={8'd0,pulse_level,16'd0};
                    default:trace_work[127:96]<={8'd0,pulse_level,16'd0};
                    endcase
                end
                j<=0;state<=PULSE_STEP;
            end
            PULSE_STEP: begin
                if(pulse_entry[23:16]==0)begin pulse_word<=pulse_entry;state<=PULSE_SAVE;end
                else begin
                    pos_old<=pulse_entry[15:0];pos_new<=pulse_entry[15:0]+active_cfg[5];
                    pulse_position<={1'b0,pulse_entry[15:0]}+{1'b0,active_cfg[5]};
                    pulse_age<=pulse_entry[31:24]==255 ? 8'd255 : pulse_entry[31:24]+8'd1;
                    pulse_peak<=pulse_entry[23:16];
                    if(pulse_entry[31:24]>=3)begin mul_a<={3'd0,pulse_entry[23:16]};mul_b<=9'd240;mul_return<=PULSE_FINALIZE;state<=WAIT_MUL;end
                    else state<=PULSE_FINALIZE;
                end
            end
            PULSE_FINALIZE:begin
                c=pulse_age>3 ? {24'd0,mul_result[15:8]} : {24'd0,pulse_peak};
                pulse_amp<=pulse_age==1 ? two_thirds_rom(c[7:0]) : c[7:0];q<=0;
                pulse_word<={pulse_age,(pulse_position>={1'b0,trace_work[15:0]} || c<14 ? 8'd0 : c[7:0]),pos_new};state<=PULSE_NODE;
            end
            PULSE_NODE: if(q>=trace_meta[27:26]) state<=PULSE_SAVE;
                else begin pulse_node_meta<=trace_node_meta;bus_addr<=11'd1152+{3'd0,trace_node_meta[13:7],1'b0};bus_word<=0;bus_length<=2;bus_kind<=LOAD_NODE;bus_return<=PULSE_HIT;state<=BUS_R_REQ;end
            PULSE_HIT: begin
                a={25'd0,pulse_node_meta[6:0]}<<4;q<=q+2'd1;
                if({16'd0,pos_old}<a && {16'd0,pos_new}>=a && pulse_amp>record_rdata[23:16]) begin
                    bus_wdata<={record_rdata[31:24],pulse_amp,record_rdata[15:0]};bus_addr<=11'd1152+{3'd0,pulse_node_meta[13:7],1'b0};bus_word<=0;bus_length<=2;bus_kind<=LOAD_NODE;bus_return<=PULSE_NODE;state<=BUS_W;
                end else state<=PULSE_NODE;
            end
            PULSE_SAVE:begin
                case(j)0:trace_work[63:32]<=pulse_word;1:trace_work[95:64]<=pulse_word;default:trace_work[127:96]<=pulse_word;endcase
                if(j==2)state<=TR_SAVE;else begin j<=j+2'd1;state<=PULSE_STEP;end
            end
            TR_SAVE: begin
                bus_addr<={1'd0,i[6:0],3'd0};bus_record<=i[6:0];bus_word<=0;bus_length<=9;bus_kind<=LOAD_TRACE;state<=BUS_W;
                if(i==69) begin i<=0;bus_return<=COMP_REQ;end else begin i<=i+8'd1;bus_return<=TR_REQ;end
            end
            COMP_REQ: begin bus_addr<={1'd0,comp_meta[6:0],3'd0};bus_word<=0;bus_length<=1;bus_kind<=LOAD_GROW;bus_return<=COMP_CAP;state<=BUS_R_REQ;end
            COMP_CAP: begin
                if(comp_fade[i[4:0]]!=0 || trace_work[15:0]>={5'd0,comp_meta[13:7],4'd0})comp_fade[i[4:0]]<=comp_fade[i[4:0]]>=242 ? 8'd255 : comp_fade[i[4:0]]+8'd13;
                if(i==17) begin i<=0;state<=NODE_REQ;end else begin i<=i+1;state<=COMP_REQ;end
            end
            NODE_REQ:begin node_meta<=node_lookup;bus_addr<={1'd0,node_lookup[6:0],3'd0};bus_word<=0;bus_length<=1;bus_kind<=LOAD_GROW;bus_return<=NODE_GROW;state<=BUS_R_REQ;end
            NODE_GROW:begin spec_index<=node_meta[20:14];bus_addr<=11'd1152+{3'd0,i[6:0],1'b0};bus_word<=0;bus_length<=2;bus_kind<=LOAD_NODE;bus_return<=NODE_CAP;state<=BUS_R_REQ;end
            NODE_CAP:begin
                node_b<=record_rdata[23:16];node_hub<=record_rdata[31:24];
                if(node_meta[22])begin
                    node_vis<=255;
                    if(lo_on>record_rdata[31:24])begin
                        if(node_meta[23])begin node_hub<=lo_on;state<=NODE_HUB_TARGET;end
                        else begin mul_a<={3'd0,lo_on};mul_b<=9'd150;mul_return<=NODE_HUB_TARGET;state<=WAIT_MUL;end
                    end else state<=NODE_HUB_TARGET;
                end else begin
                    node_vis<=trace_work[15:0]>={5'd0,node_meta[13:7],4'd0} ? (record_rdata[7:0]>=243 ? 8'd255 : record_rdata[7:0]+8'd12) : record_rdata[7:0];
                    pair_sum<={1'b0,spec_value}+{1'b0,bands[node_meta[26:24]]};
                    node_b<=record_rdata[23:16]==0 ? 8'd0 : record_rdata[23:16]-(record_rdata[23:16]>>2)-8'd1;
                    state<=NODE_TARGET;
                end
            end
            NODE_HUB_TARGET:begin
                c=lo_on>record_rdata[31:24] && !node_meta[23] ? {24'd0,mul_result[15:8]} : {24'd0,node_hub};
                node_target<=max8(spec_value,c[7:0]);node_hub<=c==0 ? 8'd0 : c[7:0]-(c[7:0]>>2)-8'd1;state<=NODE_RF;
            end
            NODE_TARGET:begin
                mul_a<={3'd0,(node_meta[21] ? 8'd0 : max8(pair_sum[8:1],record_rdata[23:16]))};
                mul_b<={1'b0,node_vis};mul_return<=NODE_SCALE;state<=WAIT_MUL;
            end
            NODE_SCALE:begin node_target<=mul_result[15:8];state<=NODE_RF;end
            NODE_RF:begin rf_current<=record_rdata[15:8];rf_target<=node_target;rf_drop<=2;rf_return<=NODE_SAVE;state<=RF_PREP;end
            NODE_SAVE:begin
                bus_wdata<={node_hub,node_b,rf_result,node_vis};bus_addr<=11'd1152+{3'd0,i[6:0],1'b0};bus_word<=0;bus_length<=2;bus_kind<=LOAD_NODE;state<=BUS_W;
                if(i==127)begin i<=0;bus_return<=BAR_REQ;end else begin i<=i+8'd1;bus_return<=NODE_REQ;end
            end
            BAR_REQ:begin spec_index<=i[6:0];bus_addr<=11'd1408+{3'd0,i[6:0],1'b0};bus_word<=0;bus_length<=2;bus_kind<=LOAD_BAR;bus_return<=BAR_CAP;state<=BUS_R_REQ;end
            BAR_CAP:begin rf_current<=record_rdata[7:0];rf_target<=spec_value;rf_drop<=3;rf_return<=BAR_HEIGHT;state<=RF_PREP;end
            BAR_HEIGHT:begin bar_height<=rf_result;bar_peak<=record_rdata[15:8];bar_hold<=record_rdata[23:16];state<=BAR_PEAK;end
            BAR_PEAK:begin
                if(bar_height>=bar_peak)begin bar_peak<=bar_height;bar_hold<=18;end
                else if(bar_hold!=0)bar_hold<=bar_hold-8'd1;
                else bar_peak<=bar_peak<3 ? bar_height : max8(bar_height,bar_peak-8'd3);
                state<=BAR_SAVE;
            end
            BAR_SAVE:begin
                bus_wdata<={8'd0,bar_hold,bar_peak,bar_height};bus_addr<=11'd1408+{3'd0,i[6:0],1'b0};bus_word<=0;bus_length<=2;bus_kind<=LOAD_BAR;state<=BUS_W;
                if(i==127)begin i<=0;bus_return<=T1_REQ;end else begin i<=i+8'd1;bus_return<=BAR_REQ;end
            end
            T1_REQ:begin
                if(i>=70)begin trace_work<=0;j<=0;state<=T1_WRITE;end
                else begin bus_addr<={1'd0,i[6:0],3'd0};bus_word<=0;bus_length<=8;bus_kind<=LOAD_TRACE;bus_return<=T1_CAP;state<=BUS_R_REQ;end
            end
            T1_CAP:begin j<=0;state<=T1_WRITE;end
            T1_WRITE:begin
                state_wr_en<=1;state_wr_sel<=0;state_wr_addr<=i[7:0];state_wr_lane<=j[1:0];state_wr_data<=trace_work[31:0];trace_work<=trace_work>>32;
                if(j==3)begin if(i==127)begin i<=0;state<=T2_REQ;end else begin i<=i+1;state<=T1_REQ;end end else j<=j+1;
            end
            T2_REQ:begin
                if(i<128)begin bus_addr<=(i<64 ? 11'd1152 : 11'd1408)+{3'd0,i[5:0],2'd0};bus_word<=0;bus_length<=2;bus_kind<=i<64 ? LOAD_NODE : LOAD_BAR;bus_return<=T2_EVEN;state<=BUS_R_REQ;end
                else state<=T2_WRITE;
            end
            T2_EVEN:begin even_word<=i<64 ? record_rdata[15:0] : record_rdata[15:0];bus_addr<=(i<64 ? 11'd1152 : 11'd1408)+{3'd0,i[5:0],2'd0}+11'd2;bus_word<=0;bus_return<=T2_ODD;state<=BUS_R_REQ;end
            T2_ODD:begin trace_work[31:0]<=i<64 ? {record_rdata[15:0],even_word} : {record_rdata[15:0],even_word};state<=T2_WRITE;end
            T2_WRITE:begin
                state_wr_en<=1;state_wr_sel<=1;state_wr_addr<=i[7:0];state_wr_lane<=0;
                if(i<128) state_wr_data<=trace_work[31:0];
                else case(i)
                128:state_wr_data<={comp_fade[3],comp_fade[2],comp_fade[1],comp_fade[0]};
                129:state_wr_data<={comp_fade[7],comp_fade[6],comp_fade[5],comp_fade[4]};
                130:state_wr_data<={comp_fade[11],comp_fade[10],comp_fade[9],comp_fade[8]};
                131:state_wr_data<={comp_fade[15],comp_fade[14],comp_fade[13],comp_fade[12]};
                132:state_wr_data<={comp_fade[19],comp_fade[18],comp_fade[17],comp_fade[16]};
                133:state_wr_data<={12'd0,comet_pos[0],comet_dir[0],comet_amp[0]};
                134:state_wr_data<={12'd0,comet_pos[1],comet_dir[1],comet_amp[1]};
                135:state_wr_data<={12'd0,comet_pos[2],comet_dir[2],comet_amp[2]};
                136:state_wr_data<={12'd0,comet_pos[3],comet_dir[3],comet_amp[3]};
                137:state_wr_data<={beat_k,chip_ink,8'd255,8'd0};
                138:state_wr_data<={bands[3],bands[2],bands[1],bands[0]};
                default:state_wr_data<={bands[7],bands[6],bands[5],bands[4]};
                endcase
                if(i==139)state<=DRAIN; else begin i<=i+1;state<=T2_REQ;end
            end
            DRAIN:state<=COMMIT;
            COMMIT:begin state_commit_toggle<=~state_commit_toggle;frame_done<=1;busy<=0;state<=IDLE;end
            default:begin err_valid<=1;err_code<=2;state<=INIT;busy<=1;init_count<=0;end
            endcase
        end
    end
endmodule
