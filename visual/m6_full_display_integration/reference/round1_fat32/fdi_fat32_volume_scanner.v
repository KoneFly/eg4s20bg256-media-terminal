`timescale 1ns/1ps
// 固定 PCB.BMP 的 FAT32 扫描器，由 052 audio043 扫描器裁剪。
// 保留 MBR/superfloppy、BPB/属性检查和首根簇连续16扇区窗口。
// 不缓存整扇区、不登记 PIC/WAV，几何乘除按 SPC 二次幂逐拍移位。
module fdi_fat32_volume_scanner (
 input wire clk,rst_n,scan_start,
 output wire scan_busy,output reg scan_done,
 output reg [7:0] fs_error,sectors_per_cluster,
 output reg [31:0] fat_start_lba,data_start_lba,max_cluster,
 output reg resource_valid,output reg [31:0] resource_cluster,resource_size,
 output reg sector_req,output reg [31:0] sector_lba,
 input wire sector_busy,sector_valid,input wire [7:0] sector_byte,
 input wire [8:0] sector_byte_index,input wire sector_done,input wire [7:0] sector_error
);
 localparam IDLE=0,R0_REQ=1,R0_WAIT=2,BOOT_REQ=3,BOOT_WAIT=4,CHECK=5,
 LAYOUT0=6,LAYOUT1=7,DIVIDE=8,ROOT_SHIFT=9,ROOT_ADD=10,DIR_REQ=11,DIR_WAIT=12,DIR_NEXT=13,FINISH=14;
 reg [3:0] state;
 reg [31:0] part_lba,total_sectors,fat_sectors,root_cluster,fat_span;
 reg [31:0] data_sectors,root_lba,arith;
 reg [15:0] reserved;
 reg [7:0] jump_byte,part_type,fat_count,spc_work,signature0,signature1;
 reg [3:0] shift_left;
 reg invalid_fields;
 reg [4:0] root_sector;
 reg name_match,entry_match,sector_zero;
 reg [15:0] cluster_hi,cluster_lo;
 reg [23:0] size_lo;
 wire boot_bytes=(state==R0_WAIT || state==BOOT_WAIT) && sector_valid;
 assign scan_busy=state!=IDLE;
 function [7:0] name_byte;
 input [3:0] i;
 begin case(i)
 0:name_byte="P";1:name_byte="C";2:name_byte="B";
 8:name_byte="B";9:name_byte="M";10:name_byte="P";
 default:name_byte=" ";endcase end
 endfunction
 task fail;
 input [7:0] code;
 begin fs_error<=code;state<=FINISH;end
 endtask
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
 state<=IDLE;scan_done<=0;fs_error<=0;sector_req<=0;sector_lba<=0;
 sectors_per_cluster<=0;fat_start_lba<=0;data_start_lba<=0;max_cluster<=0;
 resource_valid<=0;resource_cluster<=0;resource_size<=0;
 part_lba<=0;total_sectors<=0;fat_sectors<=0;root_cluster<=0;fat_span<=0;
 data_sectors<=0;root_lba<=0;arith<=0;reserved<=0;jump_byte<=0;part_type<=0;
 fat_count<=0;spc_work<=0;shift_left<=0;signature0<=0;signature1<=0;
 invalid_fields<=0;root_sector<=0;name_match<=0;entry_match<=0;sector_zero<=1;
 cluster_hi<=0;cluster_lo<=0;size_lo<=0;
 end else begin
 scan_done<=0;sector_req<=0;
 if(boot_bytes) begin
 case(sector_byte_index)
 0:jump_byte<=sector_byte;
 11:if(sector_byte!=0)invalid_fields<=1;
 12:if(sector_byte!=2)invalid_fields<=1;
 13:sectors_per_cluster<=sector_byte;
 14:reserved[7:0]<=sector_byte;
 15:reserved[15:8]<=sector_byte;
 16:fat_count<=sector_byte;
 17,18,22,23:if(sector_byte!=0)invalid_fields<=1;
 32:total_sectors[7:0]<=sector_byte;
 33:total_sectors[15:8]<=sector_byte;
 34:total_sectors[23:16]<=sector_byte;
 35:total_sectors[31:24]<=sector_byte;
 36:fat_sectors[7:0]<=sector_byte;
 37:fat_sectors[15:8]<=sector_byte;
 38:fat_sectors[23:16]<=sector_byte;
 39:fat_sectors[31:24]<=sector_byte;
 44:root_cluster[7:0]<=sector_byte;
 45:root_cluster[15:8]<=sector_byte;
 46:root_cluster[23:16]<=sector_byte;
 47:root_cluster[31:24]<=sector_byte;
 450:if(state==R0_WAIT)part_type<=sector_byte;
 454:if(state==R0_WAIT)part_lba[7:0]<=sector_byte;
 455:if(state==R0_WAIT)part_lba[15:8]<=sector_byte;
 456:if(state==R0_WAIT)part_lba[23:16]<=sector_byte;
 457:if(state==R0_WAIT)part_lba[31:24]<=sector_byte;
 510:signature0<=sector_byte;
 511:signature1<=sector_byte;
 default:begin end endcase
 end
 if(state==DIR_WAIT && sector_valid) begin
 if(sector_byte!=0)sector_zero<=0;
 if(sector_byte_index[4:0]==0)begin name_match<=sector_byte=="P";entry_match<=0;end
 else if(sector_byte_index[4:0]<=10)
 name_match<=name_match && sector_byte==name_byte(sector_byte_index[3:0]);
 else case(sector_byte_index[4:0])
 11:entry_match<=name_match && (sector_byte & 8'h18)==0;
 20:cluster_hi[7:0]<=sector_byte;
 21:cluster_hi[15:8]<=sector_byte;
 26:cluster_lo[7:0]<=sector_byte;
 27:cluster_lo[15:8]<=sector_byte;
 28:size_lo[7:0]<=sector_byte;
 29:size_lo[15:8]<=sector_byte;
 30:size_lo[23:16]<=sector_byte;
 31:if(entry_match)begin resource_valid<=1;resource_cluster<={cluster_hi,cluster_lo};resource_size<={sector_byte,size_lo};end
 default:begin end endcase
 end
 case(state)
 IDLE:if(scan_start)begin fs_error<=0;resource_valid<=0;part_lba<=0;invalid_fields<=0;state<=R0_REQ;end
 R0_REQ:if(!sector_busy)begin sector_lba<=0;sector_req<=1;state<=R0_WAIT;end
 R0_WAIT:if(sector_done)begin
 if(sector_error!=0)fail(8'h10);
 else if(signature0!=8'h55 || signature1!=8'haa)fail(8'h20);
 else if(jump_byte==8'heb || jump_byte==8'he9)begin part_lba<=0;state<=CHECK;end
 else if(part_type==8'h0b || part_type==8'h0c)begin sector_lba<=part_lba;invalid_fields<=0;state<=BOOT_REQ;end
 else fail(8'h21);end
 BOOT_REQ:if(!sector_busy)begin sector_req<=1;state<=BOOT_WAIT;end
 BOOT_WAIT:if(sector_done)begin if(sector_error!=0)fail(8'h10);
 else if(signature0!=8'h55 || signature1!=8'haa)fail(8'h20);else state<=CHECK;end
 CHECK:begin
 if(invalid_fields || reserved==0 || (fat_count!=1 && fat_count!=2) || sectors_per_cluster==0 ||
 (sectors_per_cluster & (sectors_per_cluster-1'b1))!=0 || total_sectors==0 || fat_sectors==0 || root_cluster<2)fail(8'h21);
 else begin fat_span<=fat_count==2 ? fat_sectors<<1 : fat_sectors;
 fat_start_lba<=part_lba+{16'd0,reserved};state<=LAYOUT0;end end
 LAYOUT0:begin arith<={16'd0,reserved}+fat_span;data_start_lba<=fat_start_lba+fat_span;state<=LAYOUT1;end
 LAYOUT1:begin if(total_sectors<=arith)fail(8'h21);
 else begin data_sectors<=total_sectors-arith;spc_work<=sectors_per_cluster;shift_left<=0;state<=DIVIDE;end end
 DIVIDE:if(spc_work!=1)begin spc_work<=spc_work>>1;data_sectors<=data_sectors>>1;shift_left<=shift_left+1'b1;end
 else begin max_cluster<=data_sectors+1'b1;arith<=root_cluster-2;state<=ROOT_SHIFT;end
 ROOT_SHIFT:if(shift_left!=0)begin arith<=arith<<1;shift_left<=shift_left-1'b1;end
 else if(root_cluster>max_cluster)fail(8'h21);else state<=ROOT_ADD;
 ROOT_ADD:begin root_lba<=data_start_lba+arith;root_sector<=0;state<=DIR_REQ;end
 DIR_REQ:if(!sector_busy)begin sector_lba<=root_lba+{27'd0,root_sector};sector_req<=1;
 sector_zero<=1;name_match<=0;entry_match<=0;state<=DIR_WAIT;end
 DIR_WAIT:if(sector_done)begin if(sector_error!=0)fail(8'h10);else state<=DIR_NEXT;end
 DIR_NEXT:if(resource_valid)state<=FINISH;
 else if(sector_zero || root_sector==15)fail(8'h22);
 else begin root_sector<=root_sector+1'b1;state<=DIR_REQ;end
 FINISH:begin scan_done<=1;state<=IDLE;end
 default:state<=IDLE;endcase
 end end
endmodule
