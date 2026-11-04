`timescale 1ns/1ps
// 副板SW选模式，ANC按键只归属于按下时的模式；多开业务SW拒绝输出。
module slave_panel_ctrl #(
    parameter [19:0] SWITCH_STABLE_LAST = 20'd999_999,
    parameter [26:0] KEY_LONG_LAST = 27'd39_999_999
)(
    input wire clk,rst_n,input wire [3:0] switches_async,
    input wire [2:0] key_down,
    input wire anc_ready,anc_calibrating,anc_fault,
    output wire [1:0] mode_request,
    output wire mode_conflict,auto_mode,
    output reg recapture_request,
    output reg anc_armed,anc_command,
    output reg [1:0] tone_select,
    output wire [13:0] frequency_hz
);
    localparam [1:0] OFF=0,LIVE=1,TF=2,ANC=3;
    (* async_reg="true" *) reg [3:0] sw_meta,sw_sync;
    reg [3:0] sw_candidate,sw_stable;
    reg [19:0] sw_count;
    reg [1:0] decoded_mode,previous_mode;
    reg previous_conflict,previous_auto;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin sw_meta<=0;sw_sync<=0;sw_candidate<=0;sw_stable<=0;sw_count<=0;end
        else begin
            sw_meta<=switches_async;sw_sync<=sw_meta;
            if(sw_sync!=sw_candidate)begin sw_candidate<=sw_sync;sw_count<=0;end
            else if(sw_stable!=sw_candidate)begin
                if(sw_count==SWITCH_STABLE_LAST)begin sw_stable<=sw_candidate;sw_count<=0;end
                else sw_count<=sw_count+20'd1;
            end else sw_count<=0;
        end
    end
    always @*begin
        case(sw_stable[2:0])
            3'b001:decoded_mode=LIVE;
            3'b010:decoded_mode=TF;
            3'b100:decoded_mode=ANC;
            default:decoded_mode=OFF;
        endcase
    end
    assign mode_request=decoded_mode;
    assign auto_mode=decoded_mode==ANC&&sw_stable[3];
    assign mode_conflict=sw_stable[2:0]!=0&&decoded_mode==OFF;
    assign frequency_hz=tone_select==0 ? 14'd250 : tone_select==1 ? 14'd500 :
                        tone_select==2 ? 14'd750 : 14'd500;

    reg [2:0] key_previous;
    reg key_active,key_blocked,key_long_seen;
    reg [1:0] key_owner,key_mode;
    reg [26:0] held_count;
    reg [2:0] short_event;
    reg long2_event;
    wire [2:0] pressed=key_down&~key_previous;
    wire one_key=key_down==3'b001||key_down==3'b010||key_down==3'b100;
    wire [2:0] owned_key=key_owner==1 ? 3'b001 : key_owner==2 ? 3'b010 : 3'b100;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            key_previous<=0;key_active<=0;key_blocked<=0;key_long_seen<=0;
            key_owner<=0;key_mode<=OFF;held_count<=0;short_event<=0;long2_event<=0;
        end else begin
            key_previous<=key_down;short_event<=0;long2_event<=0;
            if(!key_active)begin
                if(pressed!=0)begin
                    key_active<=1;key_long_seen<=0;held_count<=0;key_mode<=decoded_mode;
                    key_blocked<=!one_key||pressed!=key_down||mode_conflict;
                    key_owner<=key_down[0] ? 2'd1 : key_down[1] ? 2'd2 : 2'd3;
                end
            end else if(key_down==0)begin
                if(!key_blocked&&!key_long_seen&&key_mode==decoded_mode&&!mode_conflict&&decoded_mode==ANC)
                    short_event<=owned_key;
                key_active<=0;held_count<=0;key_blocked<=0;key_long_seen<=0;
            end else begin
                if(key_down!=owned_key||key_mode!=decoded_mode||mode_conflict)key_blocked<=1;
                if(!key_long_seen)begin
                    if(held_count==KEY_LONG_LAST)begin
                        key_long_seen<=1;
                        if(!key_blocked&&key_down==owned_key&&key_mode==ANC&&decoded_mode==ANC&&!mode_conflict&&key_owner==1)
                            long2_event<=1;
                    end else held_count<=held_count+27'd1;
                end
            end
        end
    end

    reg [1:0] recal_phase;
    wire mode_changed=previous_mode!=decoded_mode||previous_conflict!=mode_conflict||previous_auto!=auto_mode;
    wire arm_status=!anc_ready&&!anc_calibrating&&!anc_fault;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            previous_mode<=OFF;previous_conflict<=0;previous_auto<=0;anc_armed<=0;anc_command<=0;recapture_request<=0;
            tone_select<=1;recal_phase<=0;
        end else begin
            previous_mode<=decoded_mode;previous_conflict<=mode_conflict;previous_auto<=auto_mode;anc_command<=0;recapture_request<=0;
            if(mode_changed||decoded_mode!=ANC||mode_conflict)begin
                anc_armed<=0;recal_phase<=0;
                if(mode_changed&&decoded_mode==ANC&&!mode_conflict)tone_select<=1;
            end else if(long2_event)begin
                if(auto_mode)begin recapture_request<=1;tone_select<=1;end
                else tone_select<=tone_select>=2 ? 2'd0 : tone_select+2'd1;
                recal_phase<=0;
                if(anc_armed&&!arm_status)anc_command<=1;
            end else if(short_event[0])begin
                anc_armed<=1;recal_phase<=0;
                if(anc_armed&&!arm_status)anc_command<=1;
            end else if(recal_phase!=0)begin
                if(recal_phase==1)recal_phase<=2;
                else if(anc_armed&&arm_status)begin
                    // 等待控制核停止回ARM的回执，兼容输入事务寄存延迟。
                    anc_command<=1;recal_phase<=0;
                end
            end else if(short_event[1]!=short_event[2]&&anc_armed)begin
                if(short_event[1])begin if(arm_status)anc_command<=1;end
                else begin
                    anc_command<=1;
                    if(!arm_status)recal_phase<=1;
                end
            end
        end
    end
endmodule
