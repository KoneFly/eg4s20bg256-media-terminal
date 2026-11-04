// 每帧串行更新；状态 RAM 经同步读/写口访问，乘法与除法单元复用。
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
`include "pcb_dynamic_roms_v2.vh"

    localparam INIT=0, IDLE=1, AGG=2, BAND=3, BEAT=4, RC_EMIT=5, RC_MOVE=6,
      TR_REQ=7, BUS_R_REQ=8, TR_CAP=9, DIVIDE=10, DURATION=11, GROW=12,
      WAIT_MUL=13, GROW_CAP=14, FLOW=15, PULSE_ALLOC=16, PULSE_STEP=17,
      PULSE_NODE=18, PULSE_HIT=19, PULSE_SAVE=20, TR_SAVE=21,
      COMP_REQ=22, COMP_CAP=23, NODE_REQ=24, NODE_CAP=25,
      BAR_REQ=26, BAR_CAP=27, BUS_R_WAIT=28, BUS_R_TAKE=29,
      BUS_W=30, BUS_DRAIN=31, NODE_GROW=32, AGG_REQ=33, INIT_DONE=34,
      T1_REQ=49, T1_CAP=50, T1_WRITE=51, T2_REQ=52, T2_EVEN=53,
      T2_ODD=54, T2_WRITE=55,
      DRAIN=59, COMMIT=60;
    reg [5:0] state, bus_return, mul_return, div_return;
    reg ack_meta, ack_sync;
    reg [1023:0] spectrum;
    reg [15:0] cfg [0:7], active_cfg [0:7];
    reg [7:0] bands [0:7], onset [0:7], cooldown [0:7];
    reg [15:0] flux_average [0:7];
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
    reg [143:0] bus_wdata;
    localparam LOAD_TRACE=0, LOAD_NODE=1, LOAD_BAR=2, LOAD_PREV=3, LOAD_GROW=4;
    reg [127:0] trace_rdata, trace_work;
    reg signed [15:0] start_rdata, start_work;
    reg [31:0] node_rdata, bar_rdata;
    pcb_ram_2k16 state_bank(clk,ram_we,ram_addr,ram_addr,ram_wdata,ram_q);
    reg signed [15:0] mul_a, mul_b;
    reg signed [31:0] mul_result;
    always @(posedge clk) mul_result <= mul_a * mul_b;
    reg [15:0] div_num, div_den, div_rem, div_quot;
    reg [3:0] div_bit;
    wire [16:0] div_trial = {div_rem, div_num[div_bit]};

    reg [7:0] i;
    reg [1:0] j, q, rc;
    reg [6:0] k, strongest;
    reg emit_dir;
    reg [11:0] sum_spec, flux;
    reg [7:0] max_spec, strongest_value;
    integer a, b, c, d, e, f, pulse_age;
    reg [1:0] slot;
    reg found;
    reg [15:0] pos_old, pos_new;
    reg [7:0] pulse_amp;
    reg [31:0] pulse_word;
    reg [15:0] even_word;
    wire [27:0] trace_meta = trace_rom(state==INIT ? init_count[6:0] : i[6:0]);
    wire [13:0] trace_node_meta = trace_node_rom({i[6:0], q[0]});
    wire [26:0] node_meta = node_rom(i[6:0]);
    wire [13:0] comp_meta = comp_rom(i[4:0]);
    wire [6:0] pulse_offset = {j+2'd1,5'd0};
    // 每个控制步骤只使用一个谱读数，避免复制 128:1 选择器。
    wire [6:0] spec_index = state==FLOW ? trace_meta[13:7] :
      state==NODE_CAP ? node_meta[20:14] : state==BAR_CAP ? i[6:0] : k;
    wire [7:0] spec_value = spectrum[{spec_index,3'd0}+:8];
    assign frame_ready = !busy && ack_sync == state_commit_toggle;

    function integer max2;
        input integer x, y;
        begin max2 = x > y ? x : y; end
    endfunction
    function integer min2;
        input integer x, y;
        begin min2 = x < y ? x : y; end
    endfunction
    function [15:0] clamp;
        input [31:0] x;
        input integer low, high;
        begin clamp=x<low ? low[15:0] : x>high ? high[15:0] : x[15:0];end
    endfunction
    function integer signed16;
        input [15:0] x;
        begin signed16={{16{x[15]}},x};end
    endfunction
    function integer rise_fall;
        input integer current, target;
        integer delta;
        begin
            delta=target-current;
            rise_fall = target > current ? current + (((delta<<1)+delta+3) >> 2) : max2(target, current-(current>>4)-2);
        end
    endfunction
    function [31:0] mul8;
        input [7:0] x, y;
        integer n;
        reg [15:0] acc;
        begin
            acc=0;
            for(n=0;n<8;n=n+1) if(y[n]) acc=acc+({8'd0,x}<<n);
            mul8={16'd0,acc};
        end
    endfunction
    function [8:0] smooth;
        input [7:0] p;
        reg [8:0] low, delta;
        reg [8:0] interp;
        begin
            low=smooth_rom({1'b0,p[7:2]});
            delta=smooth_rom({1'b0,p[7:2]}+7'd1)-low;
            case(p[1:0])
            2'd0: interp=0;
            2'd1: interp=delta>>2;
            2'd2: interp=delta>>1;
            default: interp=delta-((delta+9'd3)>>2);
            endcase
            smooth=low+interp;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            ack_meta<=0; ack_sync<=0;
        end else begin ack_meta<=snapshot_ack_toggle; ack_sync<=ack_meta; end
    end
    // 算术临时量使用 integer，所有 RAM/写口边界显式截取已验证的字段位宽。
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=INIT; busy<=1; frame_accept<=0; frame_done<=0;
            state_commit_toggle<=0; state_wr_en<=0;
            state_wr_sel<=0; state_wr_addr<=0; state_wr_lane<=0; state_wr_data<=0;
            err_valid<=0; err_code<=0;
            ram_we<=0;ram_addr<=0;ram_wdata<=0;init_count<=0;previous_pair<=0;
            bus_addr<=0;bus_word<=0;bus_length<=0;bus_kind<=0;bus_record<=0;bus_wdata<=0;
            trace_rdata<=0;start_rdata<=0;node_rdata<=0;bar_rdata<=0;
            mul_a<=0; mul_b<=0; div_num<=0; div_den<=1; div_rem<=0; div_quot<=0; div_bit<=0;
            bus_return<=IDLE; mul_return<=IDLE; div_return<=IDLE;
            i<=0; j<=0; q<=0; k<=0; rc<=0; emit_dir<=0;
            sum_spec<=0; max_spec<=0; flux<=0; strongest<=0;strongest_value<=0;
            frame_number<=0; beat_k<=0; lo_on<=0; chip_ink<=0;
            trace_work<=0; start_work<=0;
            pos_old<=0; pos_new<=0; pulse_amp<=0; pulse_word<=0;
            even_word<=0;
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
                0:cfg[0]<=clamp({16'd0,cfg_wr_data},30,200);
                1:cfg[1]<=clamp({16'd0,cfg_wr_data},12,90);
                2:cfg[2]<=clamp({16'd0,cfg_wr_data},0,30);
                3:cfg[3]<=clamp({16'd0,cfg_wr_data},0,32);
                4:cfg[4]<=clamp({16'd0,cfg_wr_data},0,64);
                5:cfg[5]<=clamp({16'd0,cfg_wr_data},16,96);
                6:cfg[6]<=clamp({16'd0,cfg_wr_data},64,512);
                7:cfg[7]<=clamp({16'd0,cfg_wr_data},8,64);
                default:begin end
                endcase
            end
            case(state)
            INIT: begin
                ram_we<=1;ram_addr<=init_count;ram_wdata<=0;
                if(init_count[10:7]==4'd8) ram_wdata<=trace_meta[25:21]==0 ? 16'd24+({12'd0,trace_meta[20:17]}<<3)+{12'd0,trace_meta[20:17]} : 16'hffff;
                if(init_count==2047) state<=INIT_DONE;else init_count<=init_count+11'd1;
            end
            INIT_DONE:begin state<=IDLE;busy<=0;end
            IDLE: if(frame_tick && frame_ready) begin
                spectrum<=spec_frame;frame_accept<=1;busy<=1;frame_number<=frame_number+1;
                for(a=0;a<8;a=a+1) active_cfg[a]<=cfg[a];
                i<=0;k<=0;sum_spec<=0;max_spec<=0;flux<=0;strongest<=0;strongest_value<=0;state<=AGG_REQ;
                chip_ink<=frame_number>=23 ? 8'd255 : chip_rom(frame_number[4:0]+5'd1);
            end
            AGG_REQ:begin bus_addr<=11'd1664+{5'd0,k[6:1]};bus_word<=0;bus_length<=1;bus_kind<=LOAD_PREV;bus_return<=AGG;state<=BUS_R_REQ;end
            AGG: begin
                a={24'd0,spec_value};b=k[0] ? {24'd0,previous_pair[15:8]} : {24'd0,previous_pair[7:0]};
                sum_spec<=sum_spec+{4'd0,spec_value};max_spec<=spec_value>max_spec ? spec_value : max_spec;
                c=a-b;flux<=flux+(c>0 ? c[11:0] : 12'd0);
                bus_wdata<={128'd0,(k[0] ? {spec_value,previous_pair[7:0]} : {previous_pair[15:8],spec_value})};
                bus_addr<=11'd1664+{5'd0,k[6:1]};bus_word<=0;bus_length<=1;bus_kind<=LOAD_PREV;state<=BUS_W;
                if(spec_value>strongest_value)begin strongest<=k;strongest_value<=spec_value;end
                if(k[3:0]==15) bus_return<=BAND; else begin k<=k+7'd1;bus_return<=AGG_REQ;end
            end
            BAND: begin
                b=(({20'd0,sum_spec}>>4)+{24'd0,max_spec})>>1;bands[i[2:0]]<=b[7:0];
                c={16'd0,flux_average[i[2:0]]};a=(((c<<1)+c)>>1)+{16'd0,active_cfg[6]};b=0;
                if(cooldown[i[2:0]]!=0) cooldown[i[2:0]]<=cooldown[i[2:0]]-8'd1;
                else if({20'd0,flux}>a) begin b=min2(255,110+(({20'd0,flux}-a)>>2));cooldown[i[2:0]]<=7;end
                onset[i[2:0]]<=b[7:0];c={20'd0,flux}-{16'd0,flux_average[i[2:0]]};c=c>>>3;c=c+{16'd0,flux_average[i[2:0]]};flux_average[i[2:0]]<=c[15:0];
                if(i==7) state<=BEAT;else begin i<=i+1;k<=k+1;sum_spec<=0;max_spec<=0;flux<=0;state<=AGG_REQ;end
            end
            BEAT: begin
                a=0;for(b=0;b<8;b=b+1) a=max2(a,{24'd0,onset[b]});
                c=max2(a,{24'd0,beat_k}-({24'd0,beat_k}>>3)-1);beat_k<=c[7:0];
                c=max2({24'd0,onset[0]},{24'd0,onset[1]});lo_on<=c[7:0];
                rc<=0;emit_dir<=0;state<=c>=60 ? RC_EMIT : RC_MOVE;
            end
            RC_EMIT: begin
                a=0;for(b=1;b<4;b=b+1) if(comet_amp[b]<comet_amp[a]) a=b;
                comet_pos[a]<=({3'd0,strongest[6:0]}<<3)+10'd4;
                comet_dir[a]<=emit_dir==0 ? 2'sd1 : -2'sd1;c=min2(255,{24'd0,lo_on}+60);comet_amp[a]<=c[7:0];
                if(emit_dir==1) begin rc<=0;state<=RC_MOVE;end else emit_dir<=1;
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
                LOAD_TRACE:if(bus_word==8)start_rdata<=ram_q;else trace_rdata<={ram_q,trace_rdata[127:16]};
                LOAD_NODE:node_rdata<={ram_q,node_rdata[31:16]};
                LOAD_BAR:bar_rdata<={ram_q,bar_rdata[31:16]};
                LOAD_PREV:previous_pair<=ram_q;
                default:trace_rdata[15:0]<=ram_q;
                endcase
                if(bus_word+4'd1==bus_length)state<=bus_return;
                else begin bus_word<=bus_word+4'd1;bus_addr<=bus_kind==LOAD_TRACE && bus_word==7 ? 11'd1024+{4'd0,bus_record} : bus_addr+11'd1;state<=BUS_R_REQ;end
            end
            BUS_W:begin
                ram_we<=1;ram_addr<=bus_addr;ram_wdata<=bus_wdata[15:0];bus_wdata<=bus_wdata>>16;
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
            TR_REQ: begin bus_addr<={1'd0,i[6:0],3'd0};bus_word<=0;bus_length<=9;bus_kind<=LOAD_TRACE;bus_record<=i[6:0];bus_return<=TR_CAP;state<=BUS_R_REQ;end
            TR_CAP: begin
                trace_work<=trace_rdata;
                a=signed16(start_rdata);
                if(trace_meta[25:21]==0 && trace_rdata[15:0]==0) a=24+mul8({4'd0,trace_meta[20:17]},active_cfg[2][7:0]);
                if(a<0 && comp_fade[trace_meta[25:21]-5'd1]!=0) a=frame_number;
                start_work<=a[15:0];
                div_num<=({9'd0,trace_meta[6:0]}<<5)+({9'd0,trace_meta[6:0]}<<4)+({9'd0,trace_meta[6:0]}<<3)+({9'd0,trace_meta[6:0]}<<2)+(active_cfg[0]>>1);div_den<=active_cfg[0];div_rem<=0;div_quot<=0;div_bit<=15;div_return<=DURATION;state<=DIVIDE;
            end
            DURATION: begin
                a=max2({16'd0,div_quot},{16'd0,active_cfg[1]});
                if(start_work<0 || frame_number<=signed16(start_work) || trace_work[15:0]>=({9'd0,trace_meta[6:0]}<<4)) state<=FLOW;
                else if(frame_number-signed16(start_work)>=a) begin trace_work[15:0]<={5'd0,trace_meta[6:0],4'd0};state<=FLOW;end
                else begin b=(frame_number-signed16(start_work))<<8;div_num<=b[15:0];div_den<=a[15:0];div_rem<=0;div_quot<=0;div_bit<=15;div_return<=GROW;state<=DIVIDE;end
            end
            GROW: begin mul_a<={5'd0,trace_meta[6:0],4'd0};mul_b<={7'd0,smooth(div_quot[7:0])};mul_return<=GROW_CAP;state<=WAIT_MUL;end
            GROW_CAP: begin a=max2({16'd0,trace_work[15:0]},mul_result>>>8);trace_work[15:0]<=a[15:0];state<=FLOW;end
            FLOW: begin
                a=({24'd0,spec_value}+{24'd0,bands[trace_meta[16:14]]})>>1;
                b=rise_fall({24'd0,trace_work[23:16]},a);trace_work[23:16]<=b[7:0];
                c={24'd0,trace_work[31:24]}+{16'd0,active_cfg[3]}+(mul8(b[7:0],active_cfg[4][7:0])>>8);trace_work[31:24]<=c[7:0];state<=PULSE_ALLOC;
            end
            PULSE_ALLOC: begin
                a={24'd0,onset[trace_meta[16:14]]};
                if(trace_meta[16:14]>0) a=max2(a,{24'd0,onset[trace_meta[16:14]-3'd1]}>>1);
                if(trace_meta[16:14]<7) a=max2(a,{24'd0,onset[trace_meta[16:14]+3'd1]}>>1);
                b={24'd0,lo_on};a=max2(a,((b<<7)+(b<<3)+(b<<2))>>8);slot=0;found=0;b=-1;
                for(c=0;c<3;c=c+1) begin
                    if(found==0 && trace_work[(c+1)*32+16+:8]==0) begin slot=c[1:0];found=1;end
                    else if(found==0 && $signed({16'd0,trace_work[(c+1)*32+:16]})>b) begin b={16'd0,trace_work[(c+1)*32+:16]};slot=c[1:0];end
                end
                if(({16'd0,trace_work[15:0]}>>4)>={16'd0,active_cfg[7]} && a>=60) trace_work[{slot+2'd1,5'd0}+:32]<={8'd0,a[7:0],16'd0};
                j<=0;state<=PULSE_STEP;
            end
            PULSE_STEP: begin
                if(trace_work[pulse_offset+7'd16+:8]==0) begin pulse_word<=trace_work[pulse_offset+:32];state<=PULSE_SAVE;end
                else begin
                    a={16'd0,trace_work[pulse_offset+:16]};b=a+{16'd0,active_cfg[5]};pulse_age=min2(255,{24'd0,trace_work[pulse_offset+7'd24+:8]}+1);
                    c={24'd0,trace_work[pulse_offset+7'd16+:8]};if(pulse_age>3) c=(mul8(c[7:0],8'd240)>>8);
                    d=pulse_age==1 ? {24'd0,two_thirds_rom(c[7:0])} : c;
                    pos_old<=a[15:0];pos_new<=b[15:0];pulse_amp<=d[7:0];q<=0;
                    if(b>={16'd0,trace_work[15:0]} || c<14) c=0;
                    pulse_word<={pulse_age[7:0],c[7:0],b[15:0]};state<=PULSE_NODE;
                end
            end
            PULSE_NODE: if(q>=trace_meta[27:26]) state<=PULSE_SAVE;
                else begin bus_addr<=11'd1152+{3'd0,trace_node_meta[13:7],1'b0};bus_word<=0;bus_length<=2;bus_kind<=LOAD_NODE;bus_return<=PULSE_HIT;state<=BUS_R_REQ;end
            PULSE_HIT: begin
                a={25'd0,trace_node_meta[6:0]}<<4;q<=q+2'd1;
                if({16'd0,pos_old}<a && {16'd0,pos_new}>=a && pulse_amp>node_rdata[23:16]) begin
                    bus_wdata<={112'd0,node_rdata[31:24],pulse_amp,node_rdata[15:0]};bus_addr<=11'd1152+{3'd0,trace_node_meta[13:7],1'b0};bus_word<=0;bus_length<=2;bus_kind<=LOAD_NODE;bus_return<=PULSE_NODE;state<=BUS_W;
                end else state<=PULSE_NODE;
            end
            PULSE_SAVE: begin trace_work[pulse_offset+:32]<=pulse_word;if(j==2) state<=TR_SAVE;else begin j<=j+2'd1;state<=PULSE_STEP;end end
            TR_SAVE: begin
                bus_wdata<={start_work,trace_work};bus_addr<={1'd0,i[6:0],3'd0};bus_record<=i[6:0];bus_word<=0;bus_length<=9;bus_kind<=LOAD_TRACE;state<=BUS_W;
                if(i==69) begin i<=0;bus_return<=COMP_REQ;end else begin i<=i+8'd1;bus_return<=TR_REQ;end
            end
            COMP_REQ: begin bus_addr<={1'd0,comp_meta[6:0],3'd0};bus_word<=0;bus_length<=1;bus_kind<=LOAD_GROW;bus_return<=COMP_CAP;state<=BUS_R_REQ;end
            COMP_CAP: begin
                if(comp_fade[i[4:0]]!=0 || trace_rdata[15:0]>={5'd0,comp_meta[13:7],4'd0}) begin a=min2(255,{24'd0,comp_fade[i[4:0]]}+13);comp_fade[i[4:0]]<=a[7:0];end
                if(i==17) begin i<=0;state<=NODE_REQ;end else begin i<=i+1;state<=COMP_REQ;end
            end
            NODE_REQ: begin bus_addr<={1'd0,node_meta[6:0],3'd0};bus_word<=0;bus_length<=1;bus_kind<=LOAD_GROW;bus_return<=NODE_GROW;state<=BUS_R_REQ;end
            NODE_GROW:begin bus_addr<=11'd1152+{3'd0,i[6:0],1'b0};bus_word<=0;bus_length<=2;bus_kind<=LOAD_NODE;bus_return<=NODE_CAP;state<=BUS_R_REQ;end
            NODE_CAP: begin
                a={24'd0,node_rdata[7:0]};b={24'd0,node_rdata[23:16]};c={24'd0,node_rdata[31:24]};
                if(node_meta[22]) begin
                    e={24'd0,lo_on};if(e>c) c=node_meta[23] ? e : (((e<<7)+(e<<4)+(e<<2)+(e<<1))>>8);
                    d=max2({24'd0,spec_value},c);a=255;if(c>0)c=c-(c>>2)-1;
                end else begin
                    if(trace_rdata[15:0]>={5'd0,node_meta[13:7],4'd0}) a=min2(255,a+12);
                    d=node_meta[21] ? 0 : max2(({24'd0,spec_value}+{24'd0,bands[node_meta[26:24]]})>>1,b);
                    d=mul8(d[7:0],a[7:0])>>8;if(b>0)b=b-(b>>2)-1;
                end
                e=rise_fall({24'd0,node_rdata[15:8]},d);
                bus_wdata<={112'd0,c[7:0],b[7:0],e[7:0],a[7:0]};bus_addr<=11'd1152+{3'd0,i[6:0],1'b0};bus_word<=0;bus_length<=2;bus_kind<=LOAD_NODE;state<=BUS_W;
                if(i==127)begin i<=0;bus_return<=BAR_REQ;end else begin i<=i+8'd1;bus_return<=NODE_REQ;end
            end
            BAR_REQ: begin bus_addr<=11'd1408+{3'd0,i[6:0],1'b0};bus_word<=0;bus_length<=2;bus_kind<=LOAD_BAR;bus_return<=BAR_CAP;state<=BUS_R_REQ;end
            BAR_CAP: begin
                a={24'd0,bar_rdata[7:0]};b={24'd0,spec_value};c=b>a ? rise_fall(a,b) : max2(b,a-3-(a>>4));
                e={24'd0,bar_rdata[15:8]};f={24'd0,bar_rdata[23:16]};
                if(c>=e)begin e=c;f=18;end else if(f>0)f=f-1;else e=max2(c,e-3);
                bus_wdata<={112'd0,8'd0,f[7:0],e[7:0],c[7:0]};bus_addr<=11'd1408+{3'd0,i[6:0],1'b0};bus_word<=0;bus_length<=2;bus_kind<=LOAD_BAR;state<=BUS_W;
                if(i==127)begin i<=0;bus_return<=T1_REQ;end else begin i<=i+8'd1;bus_return<=BAR_REQ;end
            end
            T1_REQ:begin bus_addr<={1'd0,i[6:0],3'd0};bus_word<=0;bus_length<=8;bus_kind<=LOAD_TRACE;bus_return<=T1_CAP;state<=BUS_R_REQ;end
            T1_CAP:begin trace_work<=i<70 ? trace_rdata : 128'd0;j<=0;state<=T1_WRITE;end
            T1_WRITE:begin
                state_wr_en<=1;state_wr_sel<=0;state_wr_addr<=i[7:0];state_wr_lane<=j[1:0];state_wr_data<=trace_work[31:0];trace_work<=trace_work>>32;
                if(j==3)begin if(i==127)begin i<=0;state<=T2_REQ;end else begin i<=i+1;state<=T1_REQ;end end else j<=j+1;
            end
            T2_REQ:begin
                if(i<128)begin bus_addr<=(i<64 ? 11'd1152 : 11'd1408)+{3'd0,i[5:0],2'd0};bus_word<=0;bus_length<=2;bus_kind<=i<64 ? LOAD_NODE : LOAD_BAR;bus_return<=T2_EVEN;state<=BUS_R_REQ;end
                else state<=T2_WRITE;
            end
            T2_EVEN:begin even_word<=i<64 ? node_rdata[15:0] : bar_rdata[15:0];bus_addr<=(i<64 ? 11'd1152 : 11'd1408)+{3'd0,i[5:0],2'd0}+11'd2;bus_word<=0;bus_return<=T2_ODD;state<=BUS_R_REQ;end
            T2_ODD:begin trace_work[31:0]<=i<64 ? {node_rdata[15:0],even_word} : {bar_rdata[15:0],even_word};state<=T2_WRITE;end
            T2_WRITE:begin
                state_wr_en<=1;state_wr_sel<=1;state_wr_addr<=i[7:0];state_wr_lane<=0;
                if(i<128) state_wr_data<=trace_work[31:0];
                else if(i<133)begin a=({24'd0,i}-128)<<2;state_wr_data<={comp_fade[a+3],comp_fade[a+2],comp_fade[a+1],comp_fade[a]};end
                else if(i<137)begin a={24'd0,i}-133;state_wr_data<={12'd0,comet_pos[a],comet_dir[a],comet_amp[a]};end
                else if(i==137)state_wr_data<={beat_k,chip_ink,8'd255,8'd0};
                else if(i==138)state_wr_data<={bands[3],bands[2],bands[1],bands[0]};
                else state_wr_data<={bands[7],bands[6],bands[5],bands[4]};
                if(i==139)state<=DRAIN; else begin i<=i+1;state<=T2_REQ;end
            end
            DRAIN:state<=COMMIT;
            COMMIT:begin state_commit_toggle<=~state_commit_toggle;frame_done<=1;busy<=0;state<=IDLE;end
            default:begin err_valid<=1;err_code<=2;state<=INIT;busy<=1;init_count<=0;end
            endcase
        end
    end
endmodule
