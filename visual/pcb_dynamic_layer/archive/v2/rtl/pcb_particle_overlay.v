// 柱顶连线：离屏期构建有序区间并发布紧凑行记录，有效期只消费预取 FIFO。
module pcb_particle_overlay (
    input wire clk, rst_n, in_valid, in_sof, in_eol,
    input wire [9:0] in_x,
    input wire [8:0] in_y,
    input wire [5:0] in_ridx,
    input wire state_commit_toggle,
    output wire [7:0] st_misc_addr,
    input wire [31:0] st_misc_rdata,
    output reg snapshot_ack_toggle,
    output reg overlay_valid, overlay_hit,
    output reg [15:0] overlay_rgb565,
    output reg [7:0] overlay_alpha,
    output reg bucket_overflow_sticky
);
`include "pcb_dynamic_roms_v2.vh"
    localparam INIT=0, IDLE=1, FETCH_REQ=2, FETCH_WAIT=3, FETCH_TAKE=4,
      HEAD_CLEAR=5, BAR_REQ=6, BAR_WAIT=7, BAR_TAKE=8, GEO_X=9,
      MUL_WAIT=10, GEO_X_TAKE=11, GEO_Y=12, GEO_Y_TAKE=13,
      LINE_START=14, DRAW=15, FLUSH=16, INS_HEAD_REQ=17, INS_HEAD_WAIT=18,
      INS_HEAD_TAKE=19, INS_CUR_REQ=20, INS_CUR_WAIT=21, INS_CUR_TAKE=22,
      MERGE_REQ=23, MERGE_WAIT=24, MERGE_TAKE=25, ALLOCATE=26, LINK=27,
      MERGE_WRITE=28, INSERT_DONE=29, TAIL=30, BAR_NEXT=31,
      PUB_HEAD_REQ=32, PUB_HEAD_WAIT=33, PUB_HEAD_TAKE=34, PUB_REQ=35,
      PUB_WAIT=36, PUB_TAKE=37, PUB_SPAN=38, PUB_DIR=39, DONE=40;
    localparam [12:0] NIL=13'h1fff;
    reg [5:0] state, mul_return;
    reg commit_meta, commit_sync, epoch;
    reg display_ready;
    reg publish_pulse /* verilator public_flat_rd */;
    reg [7:0] fetch_addr;
    assign st_misc_addr=fetch_addr;
    reg [8:0] clear_row;
    reg [6:0] bar_index;
    reg [8:0] radius;
    reg current_high, previous_high;
    reg signed [10:0] point_x, point_y, previous_x, previous_y;
    reg signed [15:0] mul_a, mul_b;
    reg signed [31:0] mul_result;
    wire [19:0] bar_vector=bar_rom(bar_index);
    wire signed [9:0] bar_ex=bar_vector[9:0],bar_ey=bar_vector[19:10];
    reg [7:0] pending_alpha, active_alpha;

    reg [15:0] bar_cache [0:63],bar_q,bar_wdata;
    reg [5:0] bar_raddr,bar_waddr;
    reg bar_we;
    reg [12:0] heads [0:511],head_q,head_wdata;
    reg [8:0] head_raddr,head_waddr;
    reg head_we;
    reg [32:0] staging [0:6143],stage_q,stage_wdata;
    reg [12:0] stage_raddr,stage_waddr;
    reg stage_we;
    wire [23:0] pool_q;
    reg [23:0] pool_wdata;
    reg [12:0] pool_raddr,pool_waddr;
    reg pool_we;
    reg [22:0] row_directory [0:511],dir_q,dir_wdata;
    reg [8:0] dir_raddr,dir_waddr;
    reg dir_we;
    always @(posedge clk) begin
        mul_result<=mul_a*mul_b;
        bar_q<=bar_cache[bar_raddr];if(bar_we&&!in_valid)bar_cache[bar_waddr]<=bar_wdata;
        head_q<=heads[head_raddr];if(head_we&&!in_valid)heads[head_waddr]<=head_wdata;
        stage_q<=staging[stage_raddr];if(stage_we&&!in_valid)staging[stage_waddr]<=stage_wdata;
        dir_q<=row_directory[dir_raddr];if(dir_we&&!in_valid)row_directory[dir_waddr]<=dir_wdata;
    end
    pcb_span_ram pool(clk,pool_we&&!in_valid,pool_waddr,pool_raddr,pool_wdata,pool_q);

    reg signed [10:0] line_x,line_y,next_x,next_y;
    reg [8:0] target_row;
    reg signed [11:0] line_err,next_err;
    reg [10:0] line_dx,line_dy;
    reg signed [1:0] line_sx,line_sy;
    reg line_last,tail_phase,resume_tail;
    reg [9:0] run_lo0,run_hi0,run_lo1,run_hi1,run_lo2,run_hi2;
    reg run_valid0,run_valid1,run_valid2;
    reg [9:0] insert_lo,insert_hi;
    reg [12:0] alloc_count,cur,prev,anchor,new_index;
    reg [19:0] prev_word;
    wire [7:0] unused_misc_peak=st_misc_rdata[31:24];
    reg [8:0] pub_row;
    reg [12:0] pool_count,row_start,pub_cur,pub_next;
    reg [9:0] row_count,pub_x,pub_end;
    integer a,b,c,d,e,f;
    function integer s11;input [10:0] x;begin s11={{21{x[10]}},x};end endfunction
    function integer s12;input [11:0] x;begin s12={{20{x[11]}},x};end endfunction
    function integer s2;input [1:0] x;begin s2={{30{x[1]}},x};end endfunction
    function integer min2;input integer x,y;begin min2=x<y?x:y;end endfunction
    function integer max2;input integer x,y;begin max2=x>y?x:y;end endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin commit_meta<=0;commit_sync<=0;end
        else begin commit_meta<=state_commit_toggle;commit_sync<=commit_meta;end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            state<=INIT;mul_return<=IDLE;epoch<=0;display_ready<=0;publish_pulse<=0;
            snapshot_ack_toggle<=0;bucket_overflow_sticky<=0;fetch_addr<=64;clear_row<=0;
            bar_index<=0;radius<=0;current_high<=0;previous_high<=0;
            point_x<=0;point_y<=0;previous_x<=0;previous_y<=0;mul_a<=0;mul_b<=0;
            pending_alpha<=0;active_alpha<=0;
            bar_we<=0;bar_raddr<=0;bar_waddr<=0;bar_wdata<=0;
            head_we<=0;head_raddr<=0;head_waddr<=0;head_wdata<=NIL;
            stage_we<=0;stage_raddr<=0;stage_waddr<=0;stage_wdata<=0;
            pool_we<=0;pool_waddr<=0;pool_wdata<=0;dir_we<=0;dir_waddr<=0;dir_wdata<=0;
            line_x<=0;line_y<=0;next_x<=0;next_y<=0;target_row<=0;line_err<=0;next_err<=0;
            line_dx<=0;line_dy<=0;line_sx<=0;line_sy<=0;line_last<=0;tail_phase<=0;resume_tail<=0;
            run_lo0<=0;run_hi0<=0;run_lo1<=0;run_hi1<=0;run_lo2<=0;run_hi2<=0;
            run_valid0<=0;run_valid1<=0;run_valid2<=0;insert_lo<=0;insert_hi<=0;
            alloc_count<=0;cur<=NIL;prev<=NIL;anchor<=NIL;new_index<=0;prev_word<=0;
            pub_row<=0;pool_count<=0;row_start<=0;pub_cur<=NIL;pub_next<=NIL;row_count<=0;pub_x<=0;pub_end<=0;
        end else begin
            publish_pulse<=0;
            if(!in_valid)begin
            bar_we<=0;head_we<=0;stage_we<=0;pool_we<=0;dir_we<=0;
            case(state)
            INIT:begin dir_we<=1;dir_waddr<=clear_row;dir_wdata<=0;if(clear_row==479)state<=IDLE;else clear_row<=clear_row+9'd1;end
            IDLE:if(commit_sync!=snapshot_ack_toggle)begin epoch<=commit_sync;fetch_addr<=64;state<=FETCH_REQ;end
            FETCH_REQ:state<=FETCH_WAIT;
            FETCH_WAIT:state<=FETCH_TAKE;
            FETCH_TAKE:begin
                if(fetch_addr==137)begin
                    a={24'd0,st_misc_rdata[15:8]};a=(a<<7)+(a<<5)+(a<<3)+(a<<1);pending_alpha<=a[15:8];
                    snapshot_ack_toggle<=epoch;clear_row<=0;alloc_count<=0;state<=HEAD_CLEAR;
                end else begin
                    bar_we<=1;bar_waddr<=fetch_addr[5:0];bar_wdata<={st_misc_rdata[23:16],st_misc_rdata[7:0]};
                    fetch_addr<=fetch_addr==127 ? 8'd137 : fetch_addr+8'd1;state<=FETCH_REQ;
                end
            end
            HEAD_CLEAR:begin head_we<=1;head_waddr<=clear_row;head_wdata<=NIL;
                if(clear_row==479)begin bar_index<=0;state<=BAR_REQ;end else clear_row<=clear_row+9'd1;end
            BAR_REQ:begin bar_raddr<=bar_index[6:1];state<=BAR_WAIT;end
            BAR_WAIT:state<=BAR_TAKE;
            BAR_TAKE:begin a=bar_index[0] ? {24'd0,bar_q[15:8]} : {24'd0,bar_q[7:0]};a=((a<<5)+(a<<1))>>8;radius<=9'd193+a[8:0];current_high<=a!=0;state<=GEO_X;end
            GEO_X:begin mul_a<={7'd0,radius};mul_b<={{6{bar_ex[9]}},bar_ex};mul_return<=GEO_X_TAKE;state<=MUL_WAIT;end
            MUL_WAIT:state<=mul_return;
            GEO_X_TAKE:begin a=320+(mul_result>>>8);point_x<=a[10:0];state<=GEO_Y;end
            GEO_Y:begin mul_a<={7'd0,radius};mul_b<={{6{bar_ey[9]}},bar_ey};mul_return<=GEO_Y_TAKE;state<=MUL_WAIT;end
            GEO_Y_TAKE:begin a=224+(mul_result>>>8);point_y<=a[10:0];state<=LINE_START;end
            LINE_START:begin
                if(bar_index==0 || !(current_high||previous_high))state<=BAR_NEXT;
                else begin
                    line_x<=previous_x;line_y<=previous_y;
                    a=s11(point_x)-s11(previous_x);b=s11(point_y)-s11(previous_y);
                    c=a<0?-a:a;d=b<0?-b:b;e=c-d;line_dx<=c[10:0];line_dy<=d[10:0];line_err<=e[11:0];
                    line_sx<=a>0 ? 2'sd1 : -2'sd1;line_sy<=b>0 ? 2'sd1 : -2'sd1;
                    run_valid0<=0;run_valid1<=0;run_valid2<=0;resume_tail<=0;state<=DRAW;
                end
            end
            DRAW:begin
                a=s11(line_x);b=s11(line_y);e={22'd0,run_lo0};f={22'd0,run_hi0};
                if(a>=0&&a<640&&b>=0&&b<480)begin
                    if(run_valid0)begin e=min2(e,a);f=max2(f,a);end else begin e=a;f=a;end
                    run_valid0<=1;run_lo0<=e[9:0];run_hi0<=f[9:0];
                end
                c=s12(line_err)<<1;d=s12(line_err);
                if(c> -$signed({21'd0,line_dy}))begin d=d-{21'd0,line_dy};a=a+s2(line_sx);end
                if(c<$signed({21'd0,line_dx}))begin d=d+{21'd0,line_dx};b=b+s2(line_sy);end
                if(line_x==point_x&&line_y==point_y || b!=s11(line_y))begin
                    next_x<=a[10:0];next_y<=b[10:0];next_err<=d[11:0];line_last<=line_x==point_x&&line_y==point_y;state<=FLUSH;
                end else begin line_x<=a[10:0];line_y<=b[10:0];line_err<=d[11:0];end
            end
            FLUSH:begin
                a=s11(line_y)-s2(line_sy);target_row<=a[8:0];e=640;f=-1;
                if(run_valid0)begin e=min2(e,{22'd0,run_lo0});f=max2(f,{22'd0,run_hi0});end
                if(run_valid1)begin e=min2(e,{22'd0,run_lo1});f=max2(f,{22'd0,run_hi1});end
                if(run_valid2)begin e=min2(e,{22'd0,run_lo2});f=max2(f,{22'd0,run_hi2});end
                e=max2(0,e-1);f=min2(639,f+1);insert_lo<=e[9:0];insert_hi<=f[9:0];resume_tail<=0;
                state<=a>=0&&a<480&&(run_valid0||run_valid1||run_valid2) ? INS_HEAD_REQ : INSERT_DONE;
            end
            TAIL:begin
                a=s11(line_y)+(tail_phase?s2(line_sy):0);target_row<=a[8:0];e=640;f=-1;
                if(run_valid1)begin e=min2(e,{22'd0,run_lo1});f=max2(f,{22'd0,run_hi1});end
                if(!tail_phase&&run_valid2)begin e=min2(e,{22'd0,run_lo2});f=max2(f,{22'd0,run_hi2});end
                e=max2(0,e-1);f=min2(639,f+1);insert_lo<=e[9:0];insert_hi<=f[9:0];resume_tail<=1;
                state<=a>=0&&a<480&&(run_valid1||(!tail_phase&&run_valid2)) ? INS_HEAD_REQ : INSERT_DONE;
            end
            INS_HEAD_REQ:begin head_raddr<=target_row;state<=INS_HEAD_WAIT;end
            INS_HEAD_WAIT:state<=INS_HEAD_TAKE;
            INS_HEAD_TAKE:begin cur<=head_q;prev<=NIL;state<=head_q==NIL ? ALLOCATE : INS_CUR_REQ;end
            INS_CUR_REQ:begin stage_raddr<=cur;state<=INS_CUR_WAIT;end
            INS_CUR_WAIT:state<=INS_CUR_TAKE;
            INS_CUR_TAKE:begin
                if({1'b0,stage_q[19:10]}+11'd1<{1'b0,insert_lo})begin prev<=cur;prev_word<=stage_q[19:0];cur<=stage_q[32:20];state<=stage_q[32:20]==NIL ? ALLOCATE : INS_CUR_REQ;end
                else if({1'b0,stage_q[9:0]}>{1'b0,insert_hi}+11'd1)state<=ALLOCATE;
                else begin
                    insert_lo<=stage_q[9:0]<insert_lo ? stage_q[9:0] : insert_lo;
                    insert_hi<=stage_q[19:10]>insert_hi ? stage_q[19:10] : insert_hi;
                    anchor<=cur;cur<=stage_q[32:20];state<=stage_q[32:20]==NIL ? MERGE_WRITE : MERGE_REQ;
                end
            end
            MERGE_REQ:begin stage_raddr<=cur;state<=MERGE_WAIT;end
            MERGE_WAIT:state<=MERGE_TAKE;
            MERGE_TAKE:begin
                if({1'b0,stage_q[9:0]}<={1'b0,insert_hi}+11'd1)begin insert_hi<=stage_q[19:10]>insert_hi ? stage_q[19:10] : insert_hi;cur<=stage_q[32:20];state<=stage_q[32:20]==NIL ? MERGE_WRITE : MERGE_REQ;end
                else state<=MERGE_WRITE;
            end
            ALLOCATE:begin
                if(alloc_count==6144)begin bucket_overflow_sticky<=1;state<=INSERT_DONE;end
                else begin stage_we<=1;stage_waddr<=alloc_count;stage_wdata<={cur,insert_hi,insert_lo};new_index<=alloc_count;alloc_count<=alloc_count+13'd1;state<=LINK;end
            end
            LINK:begin
                if(prev==NIL)begin head_we<=1;head_waddr<=target_row;head_wdata<=new_index;end
                else begin stage_we<=1;stage_waddr<=prev;stage_wdata<={new_index,prev_word[19:0]};end
                state<=INSERT_DONE;
            end
            MERGE_WRITE:begin stage_we<=1;stage_waddr<=anchor;stage_wdata<={cur,insert_hi,insert_lo};state<=INSERT_DONE;end
            INSERT_DONE:begin
                if(resume_tail)begin if(tail_phase)state<=BAR_NEXT;else begin tail_phase<=1;state<=TAIL;end end
                else begin
                    run_valid2<=run_valid1;run_lo2<=run_lo1;run_hi2<=run_hi1;
                    run_valid1<=run_valid0;run_lo1<=run_lo0;run_hi1<=run_hi0;
                    if(line_last)begin tail_phase<=0;state<=TAIL;end
                    else begin run_valid0<=0;line_x<=next_x;line_y<=next_y;line_err<=next_err;state<=DRAW;end
                end
            end
            BAR_NEXT:begin
                previous_x<=point_x;previous_y<=point_y;previous_high<=current_high;
                if(bar_index==127)begin pub_row<=0;pool_count<=0;state<=PUB_HEAD_REQ;end else begin bar_index<=bar_index+7'd1;state<=BAR_REQ;end
            end
            PUB_HEAD_REQ:begin head_raddr<=pub_row;row_start<=pool_count;row_count<=0;state<=PUB_HEAD_WAIT;end
            PUB_HEAD_WAIT:state<=PUB_HEAD_TAKE;
            PUB_HEAD_TAKE:begin pub_cur<=head_q;state<=head_q==NIL ? PUB_DIR : PUB_REQ;end
            PUB_REQ:begin stage_raddr<=pub_cur;state<=PUB_WAIT;end
            PUB_WAIT:state<=PUB_TAKE;
            PUB_TAKE:begin pub_x<=stage_q[9:0];pub_end<=stage_q[19:10];pub_next<=stage_q[32:20];state<=PUB_SPAN;end
            PUB_SPAN:begin
                if(pool_count==6144)begin bucket_overflow_sticky<=1;state<=PUB_DIR;end
                else begin
                    a=min2(64,{22'd0,pub_end}-{22'd0,pub_x}+1);b=a-1;
                    pool_we<=1;pool_waddr<=pool_count;pool_wdata<={8'd170,b[5:0],pub_x};pool_count<=pool_count+13'd1;row_count<=row_count+10'd1;
                    if({22'd0,pub_x}+a>{22'd0,pub_end})begin pub_cur<=pub_next;state<=pub_next==NIL ? PUB_DIR : PUB_REQ;end
                    else begin a={22'd0,pub_x}+a;pub_x<=a[9:0];end
                end
            end
            PUB_DIR:begin dir_we<=1;dir_waddr<=pub_row;dir_wdata<={row_count,row_start};if(pub_row==479)state<=DONE;else begin pub_row<=pub_row+9'd1;state<=PUB_HEAD_REQ;end end
            DONE:begin active_alpha<=pending_alpha;display_ready<=1;publish_pulse<=1;state<=IDLE;end
            default:state<=INIT;
            endcase
            end
        end
    end

    // 同步行表/区段读口的生产者；有序 FIFO 提前取数，不在有效区扫描几何。
    localparam PF_IDLE=0,PF_DIR_REQ=1,PF_DIR_WAIT=2,PF_DIR_TAKE=3,PF_REQ=4,PF_WAIT=5,PF_TAKE=6;
    reg [2:0] pf_state;
    reg [8:0] pf_row;
    reg [12:0] pf_addr;
    reg [9:0] pf_left;
    reg [32:0] fifo [0:15];
    reg [3:0] fifo_rd,fifo_wr;
    reg [4:0] fifo_count;
    wire [32:0] fifo_head=fifo[fifo_rd];
    wire [10:0] head_end={1'b0,fifo_head[9:0]}+{5'd0,fifo_head[15:10]};
    wire pop=in_valid&&fifo_count!=0&&(fifo_head[32:24]<in_y || fifo_head[32:24]==in_y&&{1'b0,in_x}>=head_end);
    wire push=pf_state==PF_TAKE&&fifo_count<16;
    wire hit=display_ready&&in_valid&&fifo_count!=0&&fifo_head[23:16]==8'd170&&fifo_head[32:24]==in_y&&in_x>=fifo_head[9:0]&&{1'b0,in_x}<=head_end;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin pf_state<=PF_IDLE;pf_row<=0;pf_addr<=0;pf_left<=0;dir_raddr<=0;pool_raddr<=0;fifo_rd<=0;fifo_wr<=0;fifo_count<=0;end
        else if(publish_pulse || in_valid&&in_sof&&display_ready)begin pf_state<=PF_DIR_REQ;pf_row<=0;fifo_rd<=0;fifo_wr<=0;fifo_count<=0;end
        else begin
            case({push,pop})2'b10:fifo_count<=fifo_count+5'd1;2'b01:fifo_count<=fifo_count-5'd1;default:begin end endcase
            if(pop)fifo_rd<=fifo_rd+4'd1;
            if(push)begin fifo[fifo_wr]<={pf_row,pool_q};fifo_wr<=fifo_wr+4'd1;end
            case(pf_state)
            PF_DIR_REQ:begin dir_raddr<=pf_row;pf_state<=PF_DIR_WAIT;end
            PF_DIR_WAIT:pf_state<=PF_DIR_TAKE;
            PF_DIR_TAKE:begin pf_addr<=dir_q[12:0];pf_left<=dir_q[22:13];if(dir_q[22:13]!=0)pf_state<=PF_REQ;else if(pf_row==479)pf_state<=PF_IDLE;else begin pf_row<=pf_row+9'd1;pf_state<=PF_DIR_REQ;end end
            PF_REQ:if(fifo_count<16)begin pool_raddr<=pf_addr;pf_state<=PF_WAIT;end
            PF_WAIT:pf_state<=PF_TAKE;
            PF_TAKE:if(push)begin pf_addr<=pf_addr+13'd1;pf_left<=pf_left-10'd1;if(pf_left!=1)pf_state<=PF_REQ;else if(pf_row==479)pf_state<=PF_IDLE;else begin pf_row<=pf_row+9'd1;pf_state<=PF_DIR_REQ;end end
            default:begin end
            endcase
        end
    end
    reg [27:0] packet;
    reg [27:0] delay_mem [0:645];
    reg [9:0] delay_addr,delay_fill;
    reg sof_delayed /* verilator public_flat_rd */;
    reg eol_delayed /* verilator public_flat_rd */;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin packet<=0;delay_addr<=0;delay_fill<=0;overlay_valid<=0;overlay_hit<=0;overlay_rgb565<=0;overlay_alpha<=0;sof_delayed<=0;eol_delayed<=0;end
        else begin
            packet<={in_sof,in_eol,in_valid,hit,(hit ? bar_color_rom(in_ridx) : 16'd0),(hit ? active_alpha : 8'd0)};
            delay_mem[delay_addr]<=packet;
            delay_addr<=delay_addr==645 ? 10'd0 : delay_addr+10'd1;
            if(delay_fill<646)begin delay_fill<=delay_fill+10'd1;overlay_valid<=0;overlay_hit<=0;overlay_rgb565<=0;overlay_alpha<=0;sof_delayed<=0;eol_delayed<=0;end
            else {sof_delayed,eol_delayed,overlay_valid,overlay_hit,overlay_rgb565,overlay_alpha}<=delay_mem[delay_addr];
        end
    end
endmodule
