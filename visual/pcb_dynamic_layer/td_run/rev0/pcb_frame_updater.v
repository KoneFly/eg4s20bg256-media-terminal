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
    output reg part_wr_en,
    output reg [10:0] part_wr_addr,
    output reg [15:0] part_wr_data,
    output reg state_commit_toggle,
    output wire frame_ready,
    output reg frame_accept, frame_done, busy, err_valid,
    output reg [3:0] err_code
);
`include "pcb_dynamic_roms.vh"

    localparam INIT=0, IDLE=1, AGG=2, BAND=3, BEAT=4, RC_EMIT=5, RC_MOVE=6,
      TR_REQ=7, WAIT_RAM=8, TR_CAP=9, DIVIDE=10, DURATION=11, GROW=12,
      WAIT_MUL=13, GROW_CAP=14, FLOW=15, PULSE_ALLOC=16, PULSE_STEP=17,
      PULSE_NODE=18, PULSE_HIT=19, PULSE_SAVE=20, TR_SAVE=21,
      COMP_REQ=22, COMP_CAP=23, NODE_REQ=24, NODE_CAP=25,
      BAR_REQ=26, BAR_CAP=27, FREE_REQ=28, FREE_CAP=29,
      EMIT_X=30, EMIT_X_CAP=31, EMIT_Y=32, EMIT_Y_CAP=33,
      EMIT_VX=34, EMIT_VX_CAP=35, EMIT_TX=36, EMIT_TX_CAP=37,
      EMIT_VY=38, EMIT_VY_CAP=39, EMIT_TY=40, EMIT_SAVE=41,
      BAR_NEXT=42, PART_REQ=43, PART_CAP=44, SQUARE_X=45,
      SQUARE_X_CAP=46, SQUARE_Y=47, PART_SAVE=48,
      T1_REQ=49, T1_CAP=50, T1_WRITE=51, T2_REQ=52, T2_EVEN=53,
      T2_ODD=54, T2_WRITE=55, P_REQ=56, P_CAP=57, P_WRITE=58,
      DRAIN=59, COMMIT=60;
    reg [6:0] state, ram_return, mul_return, div_return;
    reg ack_meta, ack_sync;
    reg [1023:0] spectrum;
    reg [15:0] cfg [0:12], active_cfg [0:12];
    reg [7:0] previous [0:127], bands [0:7], onset [0:7], cooldown [0:7];
    reg [15:0] flux_average [0:7];
    reg [7:0] beat_k, lo_on, chip_ink, comp_fade [0:19];
    reg [9:0] comet_pos [0:3];
    reg signed [1:0] comet_dir [0:3];
    reg [7:0] comet_amp [0:3];
    reg [31:0] frame_number;
    reg [15:0] lfsr;
    reg [6:0] p_head;

    reg [127:0] trace_mem [0:127], trace_rdata, trace_wdata, trace_work;
    reg signed [15:0] start_mem [0:127], start_rdata, start_wdata, start_work;
    reg [31:0] node_mem [0:127], node_rdata, node_wdata;
    reg [31:0] bar_mem [0:127], bar_rdata, bar_wdata;
    reg [79:0] particle_mem [0:127], particle_rdata, particle_wdata;
    reg [31:0] particle_work;
    reg [167:0] history_mem [0:127], history_rdata, history_wdata;
    reg [146:0] history_work;
    reg [6:0] trace_addr, trace_waddr, node_addr, node_waddr, bar_addr, bar_waddr, particle_addr, particle_waddr;
    reg trace_we, start_we, node_we, bar_we, particle_we, history_we;
    always @(posedge clk) begin
        trace_rdata <= trace_mem[trace_addr]; start_rdata <= start_mem[trace_addr];
        node_rdata <= node_mem[node_addr]; bar_rdata <= bar_mem[bar_addr];
        particle_rdata <= particle_mem[particle_addr]; history_rdata <= history_mem[particle_addr];
        if (trace_we) trace_mem[trace_waddr] <= trace_wdata;
        if (start_we) start_mem[trace_waddr] <= start_wdata;
        if (node_we) node_mem[node_waddr] <= node_wdata;
        if (bar_we) bar_mem[bar_waddr] <= bar_wdata;
        if (particle_we) particle_mem[particle_waddr] <= particle_wdata;
        if (history_we) history_mem[particle_waddr] <= history_wdata;
    end
    reg signed [15:0] mul_a, mul_b;
    reg signed [31:0] mul_result;
    always @(posedge clk) mul_result <= mul_a * mul_b;
    reg [15:0] div_num, div_den, div_rem, div_quot;
    reg [3:0] div_bit;
    wire [16:0] div_trial = {div_rem, div_num[div_bit]};

    integer i, j, q, k, scan, rc, emit_dir, sum_spec, max_spec, flux, strongest;
    integer energy, emitted_x, emitted_y, emitted_vx, emitted_vy;
    reg signed [15:0] radius, speed, jitter;
    integer next_x, next_y, next_vy, pixel_x, pixel_y, square_x;
    integer a, b, c, d, e, f, slot, found, pos_old, pos_new, pulse_amp, pulse_age;
    reg [31:0] pulse_word;
    reg [191:0] publish_particle;
    reg [15:0] even_word;
    reg [10:0] publish_addr;
    reg [3:0] publish_word;
    wire [27:0] trace_meta = trace_rom(i[6:0]);
    wire [13:0] trace_node_meta = trace_node_rom({i[6:0], q[0]});
    wire [23:0] node_meta = node_rom(i[6:0]);
    wire [13:0] comp_meta = comp_rom(i[4:0]);
    wire [19:0] bar_vector = bar_rom(i[6:0]);
    wire signed [9:0] bar_ex = bar_vector[9:0], bar_ey = bar_vector[19:10];
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
        begin rise_fall = target > current ? current + (((target-current)*3+3) >> 2) : max2(target, current-(current>>4)-2); end
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
            state_commit_toggle<=0; state_wr_en<=0; part_wr_en<=0;
            state_wr_sel<=0; state_wr_addr<=0; state_wr_lane<=0; state_wr_data<=0;
            part_wr_addr<=0; part_wr_data<=0; err_valid<=0; err_code<=0;
            trace_we<=0; start_we<=0; node_we<=0; bar_we<=0; particle_we<=0; history_we<=0;
            trace_addr<=0; trace_waddr<=0; node_addr<=0; node_waddr<=0;
            bar_addr<=0; bar_waddr<=0; particle_addr<=0; particle_waddr<=0;
            trace_wdata<=0; start_wdata<=0; node_wdata<=0; bar_wdata<=0; particle_wdata<=0; history_wdata<=0;
            mul_a<=0; mul_b<=0; div_num<=0; div_den<=1; div_rem<=0; div_quot<=0; div_bit<=0;
            ram_return<=IDLE; mul_return<=IDLE; div_return<=IDLE;
            i<=0; j<=0; q<=0; k<=0; scan<=0; rc<=0; emit_dir<=0;
            sum_spec<=0; max_spec<=0; flux<=0; strongest<=0;
            frame_number<=0; beat_k<=0; lo_on<=0; chip_ink<=0; lfsr<=16'hace1; p_head<=0;
            trace_work<=0; start_work<=0; particle_work<=0; history_work<=0;
            energy<=0; radius<=0; speed<=0; jitter<=0;
            emitted_x<=0; emitted_y<=0; emitted_vx<=0; emitted_vy<=0;
            next_x<=0; next_y<=0; next_vy<=0; pixel_x<=0; pixel_y<=0; square_x<=0;
            pos_old<=0; pos_new<=0; pulse_amp<=0; pulse_word<=0;
            even_word<=0; publish_particle<=0; publish_addr<=0; publish_word<=0;
            cfg[0]<=70;cfg[1]<=36;cfg[2]<=9;cfg[3]<=8;cfg[4]<=24;cfg[5]<=44;
            cfg[6]<=160;cfg[7]<=18;cfg[8]<=110;cfg[9]<=26;cfg[10]<=175;cfg[11]<=18;cfg[12]<=1;
            for(a=0;a<13;a=a+1) active_cfg[a]<=0;
            for(a=0;a<8;a=a+1) begin bands[a]<=0;onset[a]<=0;cooldown[a]<=0;flux_average[a]<=0;end
            for(a=0;a<20;a=a+1) comp_fade[a]<=0;
            for(a=0;a<4;a=a+1) begin comet_pos[a]<=0;comet_dir[a]<=0;comet_amp[a]<=0;end
            spectrum<=0;
        end else begin
            state_wr_en<=0; part_wr_en<=0; frame_accept<=0; frame_done<=0;
            trace_we<=0;start_we<=0;node_we<=0;bar_we<=0;particle_we<=0;history_we<=0;
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
                8:cfg[8]<=clamp({16'd0,cfg_wr_data},40,200);
                9:cfg[9]<=clamp({16'd0,cfg_wr_data},8,64);
                10:cfg[10]<=clamp({16'd0,cfg_wr_data},128,255);
                11:cfg[11]<=clamp({16'd0,cfg_wr_data},6,60);
                12:cfg[12]<=1;
                default:begin end
                endcase
            end
            case(state)
            INIT: begin
                trace_we<=1; start_we<=1; node_we<=1;bar_we<=1;particle_we<=1;history_we<=1;
                trace_waddr<=i[6:0];node_waddr<=i[6:0];bar_waddr<=i[6:0];particle_waddr<=i[6:0];
                trace_wdata<=0;node_wdata<=0;bar_wdata<=0;particle_wdata<=0;history_wdata<=0;
                start_wdata<=trace_meta[25:21]==0 ? 16'd24+({12'd0,trace_meta[20:17]}*16'd9) : -16'sd1;
                previous[i]<=0;
                if(i==127) begin state<=IDLE;busy<=0;end else i<=i+1;
            end
            IDLE: if(frame_tick && frame_ready) begin
                spectrum<=spec_frame;frame_accept<=1;busy<=1;frame_number<=frame_number+1;
                for(a=0;a<13;a=a+1) active_cfg[a]<=cfg[a];
                i<=0;k<=0;sum_spec<=0;max_spec<=0;flux<=0;strongest<=0;state<=AGG;
                chip_ink<=frame_number>=23 ? 8'd255 : chip_rom(frame_number[4:0]+5'd1);
            end
            AGG: begin
                a={24'd0,spectrum[k*8+:8]};b={24'd0,previous[k]};
                sum_spec<=sum_spec+a;max_spec<=max2(max_spec,a);flux<=flux+max2(0,a-b);
                previous[k]<=spectrum[k*8+:8];
                if(a>{24'd0,spectrum[strongest*8+:8]}) strongest<=k;
                if((k&15)==15) state<=BAND; else k<=k+1;
            end
            BAND: begin
                b=((sum_spec>>4)+max_spec)>>1;bands[i]<=b[7:0];
                a=({16'd0,flux_average[i]}*3>>1)+{16'd0,active_cfg[6]};b=0;
                if(cooldown[i]!=0) cooldown[i]<=cooldown[i]-8'd1;
                else if(flux>a) begin b=min2(255,110+((flux-a)>>2));cooldown[i]<=7;end
                onset[i]<=b[7:0];c={16'd0,flux_average[i]}+((flux-$signed({16'd0,flux_average[i]}))>>>3);flux_average[i]<=c[15:0];
                if(i==7) state<=BEAT;else begin i<=i+1;k<=k+1;sum_spec<=0;max_spec<=0;flux<=0;state<=AGG;end
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
                    c={22'd0,comet_pos[rc]}+$signed(comet_dir[rc])*9;comet_pos[rc]<=c[9:0];
                    comet_amp[rc]<=comet_amp[rc]-(comet_amp[rc]>>5)-8'd1;
                end
                if(rc==3) begin i<=0;state<=TR_REQ;end else rc<=rc+1;
            end
            WAIT_RAM: state<=ram_return;
            WAIT_MUL: state<=mul_return;
            DIVIDE: begin
                if(div_trial>={1'b0,div_den}) begin div_rem<=div_trial[15:0]-div_den;div_quot[div_bit]<=1;end
                else begin div_rem<=div_trial[15:0];div_quot[div_bit]<=0;end
                if(div_bit==0) state<=div_return;else div_bit<=div_bit-4'd1;
            end
            TR_REQ: begin trace_addr<=i[6:0];ram_return<=TR_CAP;state<=WAIT_RAM;end
            TR_CAP: begin
                trace_work<=trace_rdata;
                a=signed16(start_rdata);
                if(trace_meta[25:21]==0 && trace_rdata[15:0]==0) a=24+{28'd0,trace_meta[20:17]}*{16'd0,active_cfg[2]};
                if(a<0 && comp_fade[trace_meta[25:21]-5'd1]!=0) a=frame_number;
                start_work<=a[15:0];
                div_num<=({9'd0,trace_meta[6:0]}*16'd60)+(active_cfg[0]>>1);div_den<=active_cfg[0];div_rem<=0;div_quot<=0;div_bit<=15;div_return<=DURATION;state<=DIVIDE;
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
                a=({24'd0,spectrum[trace_meta[13:7]*8+:8]}+{24'd0,bands[trace_meta[16:14]]})>>1;
                b=rise_fall({24'd0,trace_work[23:16]},a);trace_work[23:16]<=b[7:0];
                c={24'd0,trace_work[31:24]}+{16'd0,active_cfg[3]}+(mul8(b[7:0],active_cfg[4][7:0])>>8);trace_work[31:24]<=c[7:0];state<=PULSE_ALLOC;
            end
            PULSE_ALLOC: begin
                a={24'd0,onset[trace_meta[16:14]]};
                if(trace_meta[16:14]>0) a=max2(a,{24'd0,onset[trace_meta[16:14]-3'd1]}>>1);
                if(trace_meta[16:14]<7) a=max2(a,{24'd0,onset[trace_meta[16:14]+3'd1]}>>1);
                a=max2(a,({24'd0,lo_on}*140)>>8);slot=0;found=0;b=-1;
                for(c=0;c<3;c=c+1) begin
                    if(found==0 && trace_work[(c+1)*32+16+:8]==0) begin slot=c;found=1;end
                    else if(found==0 && {16'd0,trace_work[(c+1)*32+:16]}>b) begin b={16'd0,trace_work[(c+1)*32+:16]};slot=c;end
                end
                if(({16'd0,trace_work[15:0]}>>4)>={16'd0,active_cfg[7]} && a>=60) trace_work[(slot+1)*32+:32]<={8'd0,a[7:0],16'd0};
                j<=0;state<=PULSE_STEP;
            end
            PULSE_STEP: begin
                if(trace_work[(j+1)*32+16+:8]==0) begin pulse_word<=trace_work[(j+1)*32+:32];state<=PULSE_SAVE;end
                else begin
                    a={16'd0,trace_work[(j+1)*32+:16]};b=a+{16'd0,active_cfg[5]};pulse_age=min2(255,{24'd0,trace_work[(j+1)*32+24+:8]}+1);
                    c={24'd0,trace_work[(j+1)*32+16+:8]};if(pulse_age>3) c=(mul8(c[7:0],8'd240)>>8);
                    d=pulse_age==1 ? {24'd0,two_thirds_rom(c[7:0])} : c;
                    pos_old<=a;pos_new<=b;pulse_amp<=d;q<=0;
                    if(b>={16'd0,trace_work[15:0]} || c<14) c=0;
                    pulse_word<={pulse_age[7:0],c[7:0],b[15:0]};state<=PULSE_NODE;
                end
            end
            PULSE_NODE: if(q>={30'd0,trace_meta[27:26]}) state<=PULSE_SAVE;
                else begin node_addr<=trace_node_meta[13:7];ram_return<=PULSE_HIT;state<=WAIT_RAM;end
            PULSE_HIT: begin
                a={25'd0,trace_node_meta[6:0]}<<4;
                if(pos_old<a && pos_new>=a && pulse_amp>{24'd0,node_rdata[23:16]}) begin node_we<=1;node_waddr<=node_addr;node_wdata<={node_rdata[31:24],pulse_amp[7:0],node_rdata[15:0]};end
                q<=q+1;state<=PULSE_NODE;
            end
            PULSE_SAVE: begin trace_work[(j+1)*32+:32]<=pulse_word;if(j==2) state<=TR_SAVE;else begin j<=j+1;state<=PULSE_STEP;end end
            TR_SAVE: begin
                trace_we<=1;start_we<=1;trace_waddr<=i[6:0];trace_wdata<=trace_work;start_wdata<=start_work;
                if(i==69) begin i<=0;state<=COMP_REQ;end else begin i<=i+1;state<=TR_REQ;end
            end
            COMP_REQ: begin trace_addr<=comp_meta[6:0];ram_return<=COMP_CAP;state<=WAIT_RAM;end
            COMP_CAP: begin
                if(comp_fade[i]!=0 || trace_rdata[15:0]>={5'd0,comp_meta[13:7],4'd0}) begin a=min2(255,{24'd0,comp_fade[i]}+13);comp_fade[i]<=a[7:0];end
                if(i==17) begin i<=0;state<=NODE_REQ;end else begin i<=i+1;state<=COMP_REQ;end
            end
            NODE_REQ: begin node_addr<=i[6:0];trace_addr<=node_meta[6:0];ram_return<=NODE_CAP;state<=WAIT_RAM;end
            NODE_CAP: begin
                a={24'd0,node_rdata[7:0]};b={24'd0,node_rdata[23:16]};c={24'd0,node_rdata[31:24]};
                if(node_meta[22]) begin
                    if({24'd0,lo_on}>c) c=node_meta[23] ? {24'd0,lo_on} : (({24'd0,lo_on}*150)>>8);
                    d=max2({24'd0,spectrum[node_meta[20:14]*8+:8]},c);a=255;if(c>0)c=c-(c>>2)-1;
                end else begin
                    if(trace_rdata[15:0]>={5'd0,node_meta[13:7],4'd0}) a=min2(255,a+12);
                    e={4'd0,trace_rom(node_meta[6:0])};
                    d=node_meta[21] ? 0 : max2(({24'd0,spectrum[node_meta[20:14]*8+:8]}+{24'd0,bands[(e>>14)&7]})>>1,b);
                    d=mul8(d[7:0],a[7:0])>>8;if(b>0)b=b-(b>>2)-1;
                end
                e=rise_fall({24'd0,node_rdata[15:8]},d);node_we<=1;node_waddr<=i[6:0];node_wdata<={c[7:0],b[7:0],e[7:0],a[7:0]};
                if(i==127)begin i<=0;state<=BAR_REQ;end else begin i<=i+1;state<=NODE_REQ;end
            end
            BAR_REQ: begin bar_addr<=i[6:0];ram_return<=BAR_CAP;state<=WAIT_RAM;end
            BAR_CAP: begin
                a={24'd0,bar_rdata[7:0]};b={24'd0,spectrum[i*8+:8]};c=b>a ? rise_fall(a,b) : max2(b,a-3-(a>>4));energy<=c;
                d={24'd0,bar_rdata[31:24]};e={24'd0,bar_rdata[15:8]};f={24'd0,bar_rdata[23:16]};
                if(c>=e)begin e=c;f=18;end else if(f>0)f=f-1;else e=max2(c,e-3);
                a=c-a;b={16'd0,(lfsr>>1) ^ (lfsr[0] ? 16'hb400 : 16'd0)};lfsr<=b[15:0];slot=((b>>8)&15)-8;jitter<=slot[15:0];
                found=0;
                if(d>0)d=d-1;
                else if((a>={16'd0,active_cfg[9]} && c>=100)||(c>={16'd0,active_cfg[10]} && (b&63)<((c-{16'd0,active_cfg[10]})>>2))) begin d=6;found=1;end
                bar_we<=1;bar_waddr<=i[6:0];bar_wdata<={d[7:0],f[7:0],e[7:0],c[7:0]};
                if(found!=0)begin k<={25'd0,p_head};scan<=0;state<=FREE_REQ;end else state<=BAR_NEXT;
            end
            FREE_REQ:begin particle_addr<=k[6:0];ram_return<=FREE_CAP;state<=WAIT_RAM;end
            FREE_CAP:begin
                if(particle_rdata[79:72]==0 || scan==127) begin
                    if(particle_rdata[79:72]!=0)k<={25'd0,p_head};
                    a=194+((energy*34)>>8);b=18+((energy*44)>>8);radius<=a[15:0];speed<=b[15:0];state<=EMIT_X;
                end else begin k<=(k+1)&127;scan<=scan+1;state<=FREE_REQ;end
            end
            EMIT_X:begin mul_a<=radius[15:0];mul_b<={{6{bar_ex[9]}},bar_ex};mul_return<=EMIT_X_CAP;state<=WAIT_MUL;end
            EMIT_X_CAP:begin emitted_x<=5120+(mul_result>>>4);state<=EMIT_Y;end
            EMIT_Y:begin mul_a<=radius[15:0];mul_b<={{6{bar_ey[9]}},bar_ey};mul_return<=EMIT_Y_CAP;state<=WAIT_MUL;end
            EMIT_Y_CAP:begin emitted_y<=3584+(mul_result>>>4);state<=EMIT_VX;end
            EMIT_VX:begin mul_a<=speed[15:0];mul_b<={{6{bar_ex[9]}},bar_ex};mul_return<=EMIT_VX_CAP;state<=WAIT_MUL;end
            EMIT_VX_CAP:begin emitted_vx<=mul_result>>>8;state<=EMIT_TX;end
            EMIT_TX:begin mul_a<=jitter[15:0];mul_b<={{6{bar_ey[9]}},bar_ey};mul_return<=EMIT_TX_CAP;state<=WAIT_MUL;end
            EMIT_TX_CAP:begin emitted_vx<=emitted_vx-(mul_result>>>8);state<=EMIT_VY;end
            EMIT_VY:begin mul_a<=speed[15:0];mul_b<={{6{bar_ey[9]}},bar_ey};mul_return<=EMIT_VY_CAP;state<=WAIT_MUL;end
            EMIT_VY_CAP:begin emitted_vy<=mul_result>>>8;state<=EMIT_TY;end
            EMIT_TY:begin mul_a<=jitter[15:0];mul_b<={{6{bar_ex[9]}},bar_ex};mul_return<=EMIT_SAVE;state<=WAIT_MUL;end
            EMIT_SAVE:begin
                a=emitted_vy+(mul_result>>>8)-10;b=120+(energy>>1);c=emitted_x>>>4;d=emitted_y>>>4;
                particle_we<=1;history_we<=1;particle_waddr<=k[6:0];
                particle_wdata<={active_cfg[8][7:0],b[7:0],a[15:0],emitted_vx[15:0],emitted_y[15:0],emitted_x[15:0]};
                history_wdata<={8{d[9:0],c[10:0]}};p_head<=k[6:0]+7'd1;state<=BAR_NEXT;
            end
            BAR_NEXT:if(i==127)begin k<=0;state<=PART_REQ;end else begin i<=i+1;state<=BAR_REQ;end
            PART_REQ:begin particle_addr<=k[6:0];ram_return<=PART_CAP;state<=WAIT_RAM;end
            PART_CAP:begin
                particle_work<={particle_rdata[79:64],particle_rdata[47:32]};history_work<=history_rdata[146:0];
                if(particle_rdata[79:72]==0)begin if(k==127)begin i<=0;state<=T1_REQ;end else begin k<=k+1;state<=PART_REQ;end end
                else begin
                    next_vy<=signed16(particle_rdata[63:48])+3;
                    next_x<=signed16(particle_rdata[15:0])+signed16(particle_rdata[47:32]);
                    next_y<=signed16(particle_rdata[31:16])+signed16(particle_rdata[63:48])+3;state<=SQUARE_X;
                end
            end
            SQUARE_X:begin pixel_x<=next_x>>>4;pixel_y<=next_y>>>4;a=(next_x>>>4)-320;mul_a<=a[15:0];mul_b<=a[15:0];mul_return<=SQUARE_X_CAP;state<=WAIT_MUL;end
            SQUARE_X_CAP:begin square_x<=mul_result;state<=SQUARE_Y;end
            SQUARE_Y:begin a=pixel_y-224;mul_a<=a[15:0];mul_b<=a[15:0];mul_return<=PART_SAVE;state<=WAIT_MUL;end
            PART_SAVE:begin
                a={24'd0,particle_work[31:24]}-1;
                if(pixel_x< -8 || pixel_x>=648 || pixel_y>=488 || (next_vy>0 && square_x+mul_result<37249))a=0;
                if(pixel_x< -1024 || pixel_x>1023 || pixel_y< -512 || pixel_y>511)begin err_valid<=1;err_code<=4;end
                particle_we<=1;history_we<=1;particle_waddr<=k[6:0];
                particle_wdata<={a[7:0],particle_work[23:16],next_vy[15:0],particle_work[15:0],next_y[15:0],next_x[15:0]};
                history_wdata<={history_work[146:0],pixel_y[9:0],pixel_x[10:0]};
                if(k==127)begin i<=0;state<=T1_REQ;end else begin k<=k+1;state<=PART_REQ;end
            end
            T1_REQ:begin trace_addr<=i[6:0];ram_return<=T1_CAP;state<=WAIT_RAM;end
            T1_CAP:begin trace_work<=i<70 ? trace_rdata : 128'd0;j<=0;state<=T1_WRITE;end
            T1_WRITE:begin
                state_wr_en<=1;state_wr_sel<=0;state_wr_addr<=i[7:0];state_wr_lane<=j[1:0];state_wr_data<=trace_work[j*32+:32];
                if(j==3)begin if(i==127)begin i<=0;state<=T2_REQ;end else begin i<=i+1;state<=T1_REQ;end end else j<=j+1;
            end
            T2_REQ:begin
                if(i<64)begin node_addr<={i[5:0],1'b0};ram_return<=T2_EVEN;state<=WAIT_RAM;end
                else if(i<128)begin bar_addr<={i[5:0],1'b0};ram_return<=T2_EVEN;state<=WAIT_RAM;end
                else state<=T2_WRITE;
            end
            T2_EVEN:begin even_word<=i<64 ? node_rdata[15:0] : bar_rdata[15:0];if(i<64)node_addr<=node_addr+7'd1;else bar_addr<=bar_addr+7'd1;ram_return<=T2_ODD;state<=WAIT_RAM;end
            T2_ODD:begin trace_work[31:0]<=i<64 ? {node_rdata[15:0],even_word} : {bar_rdata[15:0],even_word};state<=T2_WRITE;end
            T2_WRITE:begin
                state_wr_en<=1;state_wr_sel<=1;state_wr_addr<=i[7:0];state_wr_lane<=0;
                if(i<128) state_wr_data<=trace_work[31:0];
                else if(i<133)begin a=(i-128)*4;state_wr_data<={comp_fade[a+3],comp_fade[a+2],comp_fade[a+1],comp_fade[a]};end
                else if(i<137)begin a=i-133;state_wr_data<={12'd0,comet_pos[a],comet_dir[a],comet_amp[a]};end
                else if(i==137)state_wr_data<={beat_k,chip_ink,8'd255,8'd0};
                else if(i==138)state_wr_data<={bands[3],bands[2],bands[1],bands[0]};
                else state_wr_data<={bands[7],bands[6],bands[5],bands[4]};
                if(i==139)begin k<=0;publish_addr<=0;state<=P_REQ;end else begin i<=i+1;state<=T2_REQ;end
            end
            P_REQ:begin particle_addr<=k[6:0];ram_return<=P_CAP;state<=WAIT_RAM;end
            P_CAP:begin publish_particle<={7'd0,(particle_rdata[79:72]!=0),particle_rdata[79:64],history_rdata};publish_word<=0;state<=P_WRITE;end
            P_WRITE:begin
                part_wr_en<=1;part_wr_addr<=publish_addr;part_wr_data<=publish_particle[15:0];publish_particle<=publish_particle>>16;publish_addr<=publish_addr+11'd1;
                if(publish_word==11)begin if(k==127)state<=DRAIN;else begin k<=k+1;state<=P_REQ;end end else publish_word<=publish_word+4'd1;
            end
            DRAIN:state<=COMMIT;
            COMMIT:begin state_commit_toggle<=~state_commit_toggle;frame_done<=1;busy<=0;state<=IDLE;end
            default:begin err_valid<=1;err_code<=2;state<=INIT;busy<=1;i<=0;end
            endcase
        end
    end
endmodule
