`timescale 1ns/1ps
// 最低优先级整扇区读口，请求/LBA保持到完成；最多16簇，逐项查重。
module lrc_file_reader(
    input wire clk,input wire rst,input wire start,input wire cancel,
    input wire [31:0] first_cluster,input wire [13:0] file_size,input wire [7:0] spc,
    input wire [31:0] fat_lba,input wire [31:0] data_lba,input wire [31:0] max_cluster,
    output wire sector_req,output reg [31:0] sector_lba,
    input wire sector_valid,input wire [7:0] sector_byte,input wire [8:0] sector_index,
    input wire sector_done,input wire [7:0] sector_error,
    output reg file_valid,output reg [7:0] file_byte,output reg done,output reg bad_file,output wire busy,
    output wire [6:0] visited_read_address,input wire [7:0] visited_read_data,
    output wire [6:0] visited_write_address,output wire visited_we,output wire [7:0] visited_write_data
);
    localparam [3:0] IDLE=0,CHECK=1,VR=2,VW=3,VC=4,STORE=5,OFFSET=6,LBA=7,
        DATA=8,AFTER_DATA=9,FAT=10,FAT_CHECK=11,FINISH=12,FAT_GAP=13;
    reg [3:0] state;
    reg [27:0] cluster;
    reg [6:0] fat_entry;
    reg [31:0] cluster_offset;
    reg [2:0] shift_left;
    reg [13:0] remaining;
    reg [6:0] cluster_sector;
    reg [4:0] visited_count;
    reg [3:0] visited_index;
    reg [1:0] byte_index;
    reg canceled;
    reg [2:0] shift;
    reg spc_ok;
    always @*begin
        spc_ok=1;
        case(spc)
            8'd1:shift=0;8'd2:shift=1;8'd4:shift=2;8'd8:shift=3;
            8'd16:shift=4;8'd32:shift=5;8'd64:shift=6;8'd128:shift=7;
            default:begin shift=0;spc_ok=0;end
        endcase
    end
    assign busy=state!=IDLE;
    assign sector_req=state==DATA || state==FAT;
    assign visited_read_address=7'd32+{1'b0,visited_index,2'd0}+{5'd0,byte_index};
    assign visited_write_address=7'd32+{1'b0,visited_count[3:0],2'd0}+{5'd0,byte_index};
    assign visited_we=state==STORE && !rst && !cancel && !canceled;
    assign visited_write_data=(byte_index==0)?cluster[7:0]:(byte_index==1)?cluster[15:8]:
                              (byte_index==2)?cluster[23:16]:{4'd0,cluster[27:24]};
    wire [31:0] lba_a=(state==LBA)?data_lba:(state==FAT_GAP)?fat_lba:sector_lba;
    wire [31:0] lba_b=(state==LBA)?cluster_offset:(state==FAT_GAP)?{11'd0,cluster[27:7]}:32'd1;
    wire [31:0] lba_sum=lba_a+lba_b;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;cluster<=0;fat_entry<=0;cluster_offset<=0;
            shift_left<=0;remaining<=0;cluster_sector<=0;visited_count<=0;visited_index<=0;byte_index<=0;canceled<=0;
            sector_lba<=0;file_valid<=0;file_byte<=0;done<=0;bad_file<=0;
        end else begin
            file_valid<=0;done<=0;
            if(cancel && state!=IDLE)canceled<=1;
            if(state==DATA && sector_valid && remaining!=0 && !cancel && !canceled)begin
                file_byte<=sector_byte;file_valid<=1;remaining<=remaining-14'd1;
            end
            if(state==FAT && sector_valid)begin
                if(sector_index=={fat_entry,2'b00})cluster[7:0]<=sector_byte;
                if(sector_index=={fat_entry,2'b00}+9'd1)cluster[15:8]<=sector_byte;
                if(sector_index=={fat_entry,2'b00}+9'd2)cluster[23:16]<=sector_byte;
                if(sector_index=={fat_entry,2'b00}+9'd3)cluster[27:24]<=sector_byte[3:0];
            end
            if((cancel || canceled) && state!=IDLE && state!=DATA && state!=FAT && state!=FINISH)begin bad_file<=1;state<=FINISH;end
            else case(state)
                IDLE:if(start)begin
                    canceled<=0;bad_file<=0;remaining<=file_size;visited_count<=0;cluster_sector<=0;
                    cluster<=first_cluster[27:0];
                    if(file_size==0 || file_size>8192 || !spc_ok || first_cluster<2 ||
                       first_cluster>max_cluster || first_cluster>=32'h0FFFFFF8)begin bad_file<=1;state<=FINISH;end
                    else state<=CHECK;
                end
                CHECK:begin
                    visited_index<=0;byte_index<=0;
                    if(visited_count>=16)begin bad_file<=1;state<=FINISH;end
                    else state<=visited_count==0?STORE:VR;
                end
                VR:state<=VW;
                VW:begin
                    case(byte_index)
                        0:cluster_offset[7:0]<=visited_read_data;1:cluster_offset[15:8]<=visited_read_data;
                        2:cluster_offset[23:16]<=visited_read_data;default:cluster_offset[27:24]<=visited_read_data[3:0];
                    endcase
                    if(byte_index==3)state<=VC;else begin byte_index<=byte_index+2'd1;state<=VR;end
                end
                VC:if(cluster_offset[27:0]==cluster)begin bad_file<=1;state<=FINISH;end
                   else if({1'b0,visited_index}+5'd1>=visited_count)begin byte_index<=0;state<=STORE;end
                   else begin visited_index<=visited_index+4'd1;byte_index<=0;state<=VR;end
                STORE:if(byte_index==3)begin visited_count<=visited_count+5'd1;cluster_sector<=0;cluster_offset<={4'd0,(cluster-28'd2)};shift_left<=shift;state<=OFFSET;end
                      else byte_index<=byte_index+2'd1;
                OFFSET:if(shift_left!=0)begin cluster_offset<={cluster_offset[30:0],1'b0};shift_left<=shift_left-3'd1;end else state<=LBA;
                LBA:begin sector_lba<=lba_sum;state<=DATA;end
                DATA:if(sector_done)begin
                    if(sector_error!=0 || cancel || canceled)begin bad_file<=1;state<=FINISH;end
                    else if(remaining==0 || (remaining==1 && sector_valid) || {1'b0,cluster_sector}+8'd1>=spc)begin
                        state<=FAT_GAP;
                    end else begin cluster_sector<=cluster_sector+7'd1;state<=AFTER_DATA;end
                end
                AFTER_DATA:begin sector_lba<=lba_sum;state<=DATA;end
                FAT_GAP:begin sector_lba<=lba_sum;fat_entry<=cluster[6:0];cluster<=0;state<=FAT;end
                FAT:if(sector_done)begin
                    if(sector_error!=0 || cancel || canceled)begin bad_file<=1;state<=FINISH;end else state<=FAT_CHECK;
                end
                FAT_CHECK:if(cluster>=28'hFFFFFF8)begin
                    if(remaining!=0)bad_file<=1;state<=FINISH;
                end else if(remaining==0 || cluster<2 || {4'd0,cluster}>max_cluster || cluster>=28'hFFFFFF0)begin
                    bad_file<=1;state<=FINISH;
                end else state<=CHECK;
                FINISH:begin done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
