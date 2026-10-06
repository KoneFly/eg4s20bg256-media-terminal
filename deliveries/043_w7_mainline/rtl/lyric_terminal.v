`timescale 1ns/1ps
// LRC文件/缓存/索引/显示端口总成；三个发布通道均保持payload到确认。
module lyric_terminal(
    input wire ctrl_clk,input wire ctrl_rst,input wire pixel_clk,input wire pixel_rst,
    input wire mounted,input wire mount_start,input wire [1:0] wav_slot,
    input wire entry_valid,input wire [1:0] entry_slot,input wire [31:0] entry_cluster,input wire [31:0] entry_size,
    input wire [31:0] fat_lba,input wire [31:0] data_lba,input wire [31:0] max_cluster,input wire [7:0] spc,
    output wire sector_req,output wire [31:0] sector_lba,input wire sector_valid,input wire [7:0] sector_byte,
    input wire [8:0] sector_index,input wire sector_done,input wire [7:0] sector_error,
    input wire frame_tick,input wire audio_active,input wire [31:0] samples,
    input wire [6:0] read_column,output wire [7:0] character,
    output wire line_valid,output wire [6:0] line_length,output reg [10:0] scroll_offset
);
    localparam [3:0] C_IDLE=0,C_HIDE=1,C_META_R=2,C_META_W=3,C_CHECK=4,C_START=5,C_READ=6,C_PARSE=7;
    reg [3:0] ctrl_state;
    reg checked;
    reg [1:0] load_slot;
    reg [2:0] meta_byte;
    reg [31:0] first_cluster;
    reg [13:0] file_size,received;
    reg bad_size;
    reg [7:0] epoch,hide_epoch,raw_epoch;
    reg hide_request,raw_request;
    reg [13:0] raw_size;
    (* async_reg="true" *) reg [1:0] hide_ack_sync,parsed_sync;
    reg parsed_seen;
    reg hide_ack,parsed_toggle;
    reg parsed_good;
    wire reader_done,reader_bad,reader_busy,reader_valid;
    wire [7:0] reader_byte;
    wire [3:0] slots_valid;wire slot_busy;
    wire [6:0] visit_ra,visit_wa;wire [7:0] visit_q,visit_data,meta_q;wire visit_we;
    wire reader_cancel=!mounted || wav_slot!=load_slot || mount_start;
    wire [6:0] meta_ra={2'd0,load_slot,meta_byte};
    lrc_slot_store slots(.clk(ctrl_clk),.rst(ctrl_rst),.invalidate(mount_start),
        .entry_valid(entry_valid),.entry_slot(entry_slot),.entry_cluster(entry_cluster),.entry_size(entry_size),
        .valid(slots_valid),.busy(slot_busy),.read_address_a(meta_ra),.read_data_a(meta_q),
        .read_address_b(visit_ra),.read_data_b(visit_q),.visited_we(visit_we),.visited_address(visit_wa),.visited_data(visit_data));
    lrc_file_reader reader(.clk(ctrl_clk),.rst(ctrl_rst),.start(ctrl_state==C_START),.cancel(reader_cancel),
        .first_cluster(first_cluster),.file_size(file_size),.spc(spc),.fat_lba(fat_lba),.data_lba(data_lba),.max_cluster(max_cluster),
        .sector_req(sector_req),.sector_lba(sector_lba),.sector_valid(sector_valid),.sector_byte(sector_byte),.sector_index(sector_index),
        .sector_done(sector_done),.sector_error(sector_error),.file_valid(reader_valid),.file_byte(reader_byte),.done(reader_done),.bad_file(reader_bad),.busy(reader_busy),
        .visited_read_address(visit_ra),.visited_read_data(visit_q),.visited_write_address(visit_wa),.visited_we(visit_we),.visited_write_data(visit_data));
    always @(posedge ctrl_clk or posedge ctrl_rst)begin
        if(ctrl_rst)begin
            ctrl_state<=C_IDLE;checked<=0;load_slot<=0;meta_byte<=0;first_cluster<=0;file_size<=0;received<=0;bad_size<=0;
            epoch<=0;hide_epoch<=0;raw_epoch<=0;hide_request<=0;raw_request<=0;raw_size<=0;
            hide_ack_sync<=0;parsed_sync<=0;parsed_seen<=0;
        end else begin
            hide_ack_sync<={hide_ack_sync[0],hide_ack};parsed_sync<={parsed_sync[0],parsed_toggle};
            if(!mounted)checked<=0;
            if(ctrl_state==C_READ && reader_valid && !reader_cancel)received<=received+14'd1;
            case(ctrl_state)
                C_IDLE:if(mounted && !slot_busy && !reader_busy && (!checked || wav_slot!=load_slot))begin
                    load_slot<=wav_slot;checked<=1;epoch<=epoch+8'd1;hide_epoch<=epoch+8'd1;
                    hide_request<=~hide_request;ctrl_state<=C_HIDE;
                end
                C_HIDE:if(hide_ack_sync[1]==hide_request)begin
                    if(!mounted || wav_slot!=load_slot)begin checked<=0;ctrl_state<=C_IDLE;end
                    else if(!slot_busy)begin
                        if(!slots_valid[load_slot])ctrl_state<=C_IDLE;
                        else begin meta_byte<=0;first_cluster<=0;file_size<=0;bad_size<=0;ctrl_state<=C_META_R;end
                    end
                end
                C_META_R:ctrl_state<=C_META_W;
                C_META_W:begin
                    case(meta_byte)
                        0:first_cluster[7:0]<=meta_q;1:first_cluster[15:8]<=meta_q;
                        2:first_cluster[23:16]<=meta_q;3:first_cluster[31:24]<=meta_q;
                        4:file_size[7:0]<=meta_q;
                        5:begin file_size[13:8]<=meta_q[5:0];if(meta_q[7:6]!=0)bad_size<=1;end
                        default:if(meta_q!=0)bad_size<=1;
                    endcase
                    if(meta_byte==7)ctrl_state<=C_CHECK;
                    else begin meta_byte<=meta_byte+3'd1;ctrl_state<=C_META_R;end
                end
                C_CHECK:if(reader_cancel)begin checked<=0;ctrl_state<=C_IDLE;end
                        else if(bad_size || file_size==0 || file_size>8192)ctrl_state<=C_IDLE;
                        else begin received<=0;ctrl_state<=C_START;end
                C_START:ctrl_state<=C_READ;
                C_READ:if(reader_done)begin
                    if(reader_bad || reader_cancel || received!=file_size)begin
                        if(reader_cancel)checked<=0;ctrl_state<=C_IDLE;
                    end else begin
                        raw_size<=file_size;raw_epoch<=epoch;raw_request<=~raw_request;
                        parsed_seen<=parsed_sync[1];ctrl_state<=C_PARSE;
                    end
                end
                C_PARSE:if(parsed_sync[1]!=parsed_seen || reader_cancel)begin
                    if(reader_cancel)checked<=0;ctrl_state<=C_IDLE;
                end
                default:ctrl_state<=C_IDLE;
            endcase
        end
    end
    (* async_reg="true" *) reg [1:0] hide_sync,raw_sync;
    reg raw_seen;
    reg [7:0] active_epoch,parser_epoch;
    reg parser_start,parser_cancel,cache_valid;
    reg [13:0] parser_size;
    wire parser_done,parser_valid,parser_bad,parser_busy;
    wire [8:0] count;
    wire [12:0] raw_address,line_pointer,write_address;
    wire [7:0] index_address,index_view_address,sort_address_b;wire sorting;
    wire [53:0] index_data,index_q,index_q_b;wire [7:0] text_q,write_data;
    wire [2:0] index_mask;wire text_request,text_ack;
    wire [12:0] text_address;
    wire [7:0] text_data;
    wire [7:0] selected_id;wire selection_commit;
    reg [7:0] previous_id;
    wire hide_pending=hide_sync[1]!=hide_ack;
    wire visible_cache=cache_valid && !hide_pending && parsed_good;
    always @(posedge pixel_clk or posedge pixel_rst)begin
        if(pixel_rst)begin
            hide_sync<=0;raw_sync<=0;hide_ack<=0;raw_seen<=0;active_epoch<=0;parser_epoch<=0;
            parser_start<=0;parser_cancel<=0;parser_size<=0;cache_valid<=0;parsed_toggle<=0;parsed_good<=0;
            scroll_offset<=0;previous_id<=0;
        end else begin
            hide_sync<={hide_sync[0],hide_request};raw_sync<={raw_sync[0],raw_request};parser_start<=0;parser_cancel<=0;
            if(hide_pending && frame_tick)begin
                cache_valid<=0;parsed_good<=0;parser_cancel<=1;active_epoch<=hide_epoch;hide_ack<=hide_sync[1];
            end else if(raw_sync[1]!=raw_seen && !parser_busy)begin
                raw_seen<=raw_sync[1];
                if(raw_epoch==active_epoch && !hide_pending)begin
                    parser_size<=raw_size;parser_epoch<=raw_epoch;parser_start<=1;cache_valid<=0;
                end
            end
            if(parser_done)begin
                parsed_good<=parser_valid && !parser_bad && parser_epoch==active_epoch && !hide_pending;
                cache_valid<=parser_valid && !parser_bad && parser_epoch==active_epoch && !hide_pending;
                parsed_toggle<=~parsed_toggle;
            end
            // 索引扫描的中间行号不代表换行；只在完整选行提交时更新。
            if(selection_commit)previous_id<=selected_id;
            if(!line_valid || (selection_commit && selected_id!=previous_id))scroll_offset<=11'd624;
            else if(frame_tick && line_length>7'd77)begin
                if(scroll_offset>=11'd632+{1'b0,line_length,3'd0})scroll_offset<=0;
                else scroll_offset<=scroll_offset+11'd1;
            end
        end
    end
    lrc_parser_engine parser(.clk(pixel_clk),.rst(pixel_rst),.start(parser_start),.cancel(parser_cancel),.size(parser_size),
        .raw_address(raw_address),.raw_data(text_q),.text_request(text_request),.text_address(text_address),.text_data(text_data),.text_ack(text_ack),
        .index_address(index_address),.sort_address_b(sort_address_b),.sorting(sorting),.index_mask(index_mask),.index_data(index_data),.index_q(index_q),.index_q_b(index_q_b),
        .count(count),.done(parser_done),.valid(parser_valid),.bad_format(parser_bad),.busy(parser_busy));
    wire bridge_we;
    lrc_text_writer writer(.pixel_clk(pixel_clk),.pixel_rst(pixel_rst),.request(text_request),.address(text_address),.data(text_data),.epoch(parser_epoch),.acknowledge(text_ack),
        .ctrl_clk(ctrl_clk),.ctrl_rst(ctrl_rst),.accept_write(ctrl_state==C_PARSE && !reader_cancel),.expected_epoch(epoch),
        .write_enable(bridge_we),.write_address(write_address),.write_data(write_data));
    wire [12:0] ctrl_text_address=(ctrl_state==C_READ)?received[12:0]:write_address;
    wire ctrl_text_we=(ctrl_state==C_READ)?(reader_valid && !reader_cancel):bridge_we;
    wire [7:0] ctrl_text_data=(ctrl_state==C_READ)?reader_byte:write_data;
    wire [7:0] unused_text_ctrl;
    lrc_cache_memory text_cache(.ctrl_clk(ctrl_clk),.ctrl_address(ctrl_text_address),.ctrl_we(ctrl_text_we),.ctrl_data(ctrl_text_data),.ctrl_q(unused_text_ctrl),
        .pixel_clk(pixel_clk),.pixel_address(parser_busy?raw_address:(line_pointer+{6'd0,read_column})),.pixel_q(text_q));
    lrc_index_memory index_cache(.clk(pixel_clk),.address_a(index_address),.write_mask(index_mask),.data(index_data),.q_a(index_q),
        .address_b(sorting?sort_address_b:index_view_address),.q_b(index_q_b));
    lrc_viewer viewer(.clk(pixel_clk),.rst(pixel_rst),.frame_tick(frame_tick),.cache_valid(visible_cache),.count(count),
        .audio_active(audio_active),.samples(samples),.index_data(index_q_b),.index_address(index_view_address),
        .line_valid(line_valid),.line_start(line_pointer),.line_length(line_length),.line_id(selected_id),.selection_commit(selection_commit));
    assign character=text_q;
endmodule
