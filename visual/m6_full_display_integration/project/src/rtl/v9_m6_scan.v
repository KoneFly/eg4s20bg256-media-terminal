`timescale 1ns/1ps
// W2在ctrl50更新，像素域保留原三银行快照及S2双行重定时。
module v9_m6_scan (
    input wire clk,rst,snapshot_done,input wire [7:0] energy_data,
    output reg frame_request,output reg [6:0] energy_addr,
    output wire video_de,video_vs,output wire [15:0] video_rgb,
    output reg [15:0] display_frames,
    input wire ctrl_clk,ctrl_rst_n,label_ready,pixel_ready,
    input wire [31:0] pixel_data,input wire pixel_valid,
    output wire pixel_take,output reg [7:0] error_code
);
    reg [9:0] h,v;
    reg display_enabled,state_committed;
    reg [2:0] capture_state;
    localparam CAP_IDLE=0,CAP_ACK=1,CAP_PRIME=2,CAP_READ=3,CAP_WAIT=4,CAP_TRANSFER=5;
    // 串移收集128字节：首次读出的通道0最终落在[7:0]，避免可变写选择器。
    reg [1023:0] spectrum_hold;
    reg capture_toggle;
    (* ASYNC_REG="TRUE" *) reg capture_meta,capture_sync;
    reg capture_ack;
    (* ASYNC_REG="TRUE" *) reg capture_ack_meta,capture_ack_sync;
    (* ASYNC_REG="TRUE" *) reg label_meta,label_sync,ready_meta,ready_sync;
    (* ASYNC_REG="TRUE" *) reg commit_meta,commit_sync;
    reg commit_ack;
    wire state_commit,w2_ready,w2_accept,w2_done,w2_busy,w2_error;
    wire [3:0] w2_error_code;
    wire wr_en,wr_sel;
    wire [7:0] wr_addr;
    wire [31:0] wr_data;
    wire [1:0] wr_lane;
    reg frame_tick;
    wire blank_window=(v>=10'd515 || v<10'd33);
    (* ASYNC_REG="TRUE" *) reg blank_meta,blank_sync;
    reg [7:0] ctrl_error;
    (* ASYNC_REG="TRUE" *) reg [7:0] ctrl_error_meta,ctrl_error_sync;
    reg [7:0] ctrl_error_previous;
    // 更新只能在上一帧flush完毕后的VBLANK启动；握手总线直到下一请求保持。
    always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
        if(!ctrl_rst_n)begin
            capture_meta<=0;capture_sync<=0;capture_ack<=0;frame_tick<=0;
            blank_meta<=0;blank_sync<=0;ctrl_error<=0;
        end else begin
            capture_meta<=capture_toggle;capture_sync<=capture_meta;
            blank_meta<=blank_window;blank_sync<=blank_meta;frame_tick<=0;
            if(capture_sync!=capture_ack && w2_ready && blank_sync)begin
                frame_tick<=1;capture_ack<=capture_sync;
            end
            if(ctrl_error==0)begin
                if(wr_en && !blank_sync)ctrl_error<=8'ha2;
                else if(w2_error)ctrl_error<={4'hb,w2_error_code};
            end
        end
    end
    pcb_frame_updater u_updater(
        .clk(ctrl_clk),.rst_n(ctrl_rst_n),.frame_tick(frame_tick),.spec_frame(spectrum_hold),
        .cfg_wr_en(1'b0),.cfg_wr_addr(6'd0),.cfg_wr_data(16'd0),
        .snapshot_ack_toggle(commit_ack),.state_wr_en(wr_en),.state_wr_sel(wr_sel),
        .state_wr_addr(wr_addr),.state_wr_data(wr_data),.state_wr_lane(wr_lane),
        .state_commit_toggle(state_commit),.frame_ready(w2_ready),.frame_accept(w2_accept),
        .frame_done(w2_done),.busy(w2_busy),.err_valid(w2_error),.err_code(w2_error_code));
    wire input_de=display_enabled && h>=10'd144 && h<10'd784 && v>=10'd33 && v<10'd513;
    wire output_de=display_enabled && h>=10'd144 && h<10'd784 && v>=10'd35 && v<10'd515;
    assign pixel_take=input_de;
    reg take_delayed;
    wire [7:0] trace_addr,misc_addr;
    wire [127:0] trace_data;
    wire [31:0] misc_data;
    wire [15:0] rendered;
    wire rendered_valid;
    pcb_state_mem u_state_mem(.clk(clk),.st_trace_addr(trace_addr),.st_trace_rdata(trace_data),
        .st_misc_addr(misc_addr),.st_misc_rdata(misc_data),.wr_clk(ctrl_clk),.wr_en(wr_en),
        .wr_sel(wr_sel),.wr_addr(wr_addr),.wr_data(wr_data),.wr_lane(wr_lane));
    // FIFO寄存输出在take后下一拍被S2消费；首commit独立于此输入开放条件。
    pcb_pixel_renderer u_renderer(.clk(clk),.rst_n(!rst && display_enabled),
        .in_valid(take_delayed && pixel_valid),.in_label(pixel_data[31:16]),
        .in_image(pixel_data[15:0]),.ov_on(1'b0),.st_trace_addr(trace_addr),
        .st_trace_rdata(trace_data),.st_misc_addr(misc_addr),.st_misc_rdata(misc_data),
        .wr_clk(ctrl_clk),.wr_en(wr_en),.wr_sel(wr_sel),.wr_addr(wr_addr),
        .wr_data(wr_data),.wr_lane(wr_lane),.pixel_rgb565(rendered),.pixel_valid(rendered_valid));
    (* ram_style="bram_32k" *) reg [15:0] lines[0:2047];
    reg [9:0] wx;
    reg [8:0] wy;
    reg [15:0] read_pixel;
    wire [9:0] read_x=h-10'd143;
    wire [10:0] read_addr={!v[0],read_x};
    wire [10:0] line_write_addr={wy[0],wx};
    always @(posedge clk)begin
        if(rendered_valid)lines[line_write_addr]<=rendered;
        read_pixel<=lines[read_addr];
    end
    assign video_rgb=read_pixel;
    assign video_de=output_de;
    assign video_vs=v>=10'd2;
    // 监测W2是否按完整写批提交；错误落已有诊断链，不伪造ack。
    reg [9:0] write_count;
    reg write_order_bad;
    always @(posedge ctrl_clk or negedge ctrl_rst_n)begin
        if(!ctrl_rst_n)begin write_count<=0;write_order_bad<=0;end
        else begin
            if(w2_accept)write_count<=0;
            if(wr_en)begin
                if(write_count>=10'd652 || wr_sel!=(write_count>=10'd512) ||
                  (!wr_sel && (wr_addr!={1'b0,write_count[8:2]} || wr_lane!=write_count[1:0])) ||
                  (wr_sel && wr_addr!=write_count[7:0]))write_order_bad<=1;
                write_count<=write_count+1'b1;
            end
            if(w2_done && write_count!=10'd652)write_order_bad<=1;
        end
    end
    (* ASYNC_REG="TRUE" *) reg write_bad_meta,write_bad_sync;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            h<=0;v<=0;display_enabled<=0;state_committed<=0;capture_state<=CAP_IDLE;
            spectrum_hold<=0;capture_toggle<=0;frame_request<=0;energy_addr<=0;
            capture_ack_meta<=0;capture_ack_sync<=0;label_meta<=0;label_sync<=0;
            ready_meta<=0;ready_sync<=0;commit_meta<=0;commit_sync<=0;commit_ack<=0;
            ctrl_error_meta<=0;ctrl_error_sync<=0;ctrl_error_previous<=0;write_bad_meta<=0;write_bad_sync<=0;
            take_delayed<=0;wx<=0;wy<=0;display_frames<=0;error_code<=0;
        end else begin
            frame_request<=0;take_delayed<=pixel_take;
            capture_ack_meta<=capture_ack;capture_ack_sync<=capture_ack_meta;
            label_meta<=label_ready;label_sync<=label_meta;ready_meta<=w2_ready;ready_sync<=ready_meta;
            commit_meta<=state_commit;commit_sync<=commit_meta;
            ctrl_error_meta<=ctrl_error;ctrl_error_sync<=ctrl_error_meta;
            ctrl_error_previous<=ctrl_error_sync;
            write_bad_meta<=write_order_bad;write_bad_sync<=write_bad_meta;
            if(h==10'd799)begin h<=0;if(v==10'd524)v<=0;else v<=v+1'b1;end
            else h<=h+1'b1;
            if(commit_sync!=commit_ack)begin commit_ack<=commit_sync;state_committed<=1;end
            // S2完整输入帧从v33开始；先于首有效像素h144开放，无半帧消费。
            if(h==0 && v==10'd33 && state_committed && pixel_ready && error_code==0)display_enabled<=1;
            if(v==10'd515 && h==0 && display_enabled)display_frames<=display_frames+1'b1;
            if(rendered_valid)begin
                if(wx==10'd639)begin wx<=0;if(wy==9'd479)wy<=0;else wy<=wy+1'b1;end
                else wx<=wx+1'b1;
            end
            if(error_code==0)begin
                // 多位故障码跨域后连续两拍一致再锁存，避免锁住过渡组合码。
                if(ctrl_error_sync!=0 && ctrl_error_sync==ctrl_error_previous)error_code<=ctrl_error_sync;
                else if(write_bad_sync)error_code<=8'ha4;
                else if(take_delayed!=pixel_valid && display_enabled)error_code<=8'ha3;
                else if(h==0 && v==10'd33 && capture_state!=CAP_IDLE)error_code<=8'ha1;
            end
            case(capture_state)
                CAP_IDLE:if(v==10'd515 && h==0 && label_sync && ready_sync && error_code==0)begin
                    frame_request<=1;capture_state<=CAP_ACK;
                end
                CAP_ACK:if(snapshot_done)begin energy_addr<=0;capture_state<=CAP_PRIME;end
                CAP_PRIME:capture_state<=CAP_READ;
                CAP_READ:begin
                    spectrum_hold<={energy_data,spectrum_hold[1023:8]};
                    if(energy_addr==7'd127)begin capture_toggle<=!capture_toggle;capture_state<=CAP_TRANSFER;end
                    else begin energy_addr<=energy_addr+1'b1;capture_state<=CAP_WAIT;end
                end
                CAP_WAIT:capture_state<=CAP_READ;
                CAP_TRANSFER:if(capture_ack_sync==capture_toggle)capture_state<=CAP_IDLE;
                default:capture_state<=CAP_IDLE;
            endcase
        end
    end
    wire unused_updater_status=^{w2_busy};
endmodule
