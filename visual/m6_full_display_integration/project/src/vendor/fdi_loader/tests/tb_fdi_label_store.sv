`timescale 1ns/1ps
module tb_fdi_label_store;
 reg clk=0;always #10 clk=!clk;
 wire mem_clk=!clk;
 reg rst_n=0;
 wire sd_ncs,sd_dclk,sd_mosi,sd_miso,label_ready;
 wire [7:0] error_code;
 reg rd_req_valid=0;
 reg [20:0] rd_req_addr=0;
 wire rd_req_ready,rd_beat_valid,rd_done;
 wire [31:0] rd_beat_data;
 wire [20:0] rd_beat_addr;
 fdi_label_store #(.STARTUP_CYCLES(32),.BOOT_TIMEOUT_CYCLES(60000000)) dut(.*);
 sd_spi_card_model #(.IMG_SECTORS(4096)) card(
  .spi_cs_n(sd_ncs),.spi_sck(sd_dclk),.spi_mosi(sd_mosi),.spi_miso(sd_miso));
 reg [31:0] golden[0:153599];
 integer cycles=0,beats=0,i;
 integer scenario=0;
 reg corruption_applied=0;
 reg [7:0] expected_error=0;
 always @(negedge clk)begin
  if(scenario==3 && !corruption_applied && dut.state==7)begin
   dut.u_sdram.mem[21'h40064]=dut.u_sdram.mem[21'h40064]^32'd1;
   corruption_applied=1;
  end
 end
 always @(posedge clk)if(rst_n && rd_beat_valid)begin
  if(rd_beat_addr<21'h40000 || rd_beat_addr>=21'h65800)$fatal(1,"READ_ADDR %h",rd_beat_addr);
  if(rd_beat_data!==golden[rd_beat_addr-21'h40000])$fatal(1,"READ_DATA addr=%h got=%h exp=%h",rd_beat_addr,rd_beat_data,golden[rd_beat_addr-21'h40000]);
  beats=beats+1;
 end
 task read_burst;
  input [20:0] a;
  begin
   @(negedge clk);beats=0;rd_req_addr=a;rd_req_valid=1;
   while(!rd_req_ready)@(negedge clk);
   @(negedge clk);rd_req_valid=0;
   while(!rd_done && error_code==0)@(negedge clk);
   if(beats!=8 || error_code!=0)$fatal(1,"BURST beats=%0d code=%h",beats,error_code);
   @(negedge clk);
  end
 endtask
 initial begin
  $readmemh("label_words.memh",golden);
  if($value$plusargs("scenario=%d",scenario))begin end
  #1;
  case(scenario)
   1:begin card.img[(48*512+100)/4]=card.img[(48*512+100)/4]^32'h01000000;expected_error=8'h41;end
   2:begin card.img[(48*512+18)/4]=card.img[(48*512+18)/4]^32'h00000100;expected_error=8'h40;end
   3:expected_error=8'h48;
   4:begin card.img[(40*512)/4]=32'h58434220;expected_error=8'h22;end
   5:begin card.cfg_crc_bad_lba=48;expected_error=8'h10;end
   6:begin card.cfg_dead=1;expected_error=8'h83;end
   7:begin card.img[32*128+3]=32'h03000000;expected_error=8'h23;end
   8:begin card.img[32*128+3]=32'hffffff0f;expected_error=8'h25;end
   9:begin card.img[32*128+3]=32'h01000000;expected_error=8'h24;end
   10:begin card.img[32*128+228]=32'h03000000;expected_error=8'h23;end
   11:begin
    // 同一黄金文件移入偏移16扇区的第一MBR分区，独立核查分区基址。
    for(i=4096*128-1;i>=16*128;i=i-1)card.img[i]=card.img[i-16*128];
    for(i=0;i<128;i=i+1)card.img[i]=0;
    card.img[112]=32'h00000c00;card.img[113]=32'h00001000;card.img[127]=32'h000055aa;
   end
   12:begin
    // PCB目录项在第二根扇区；首扇区有删除项而非全0结束标记。
    for(i=0;i<8;i=i+1)begin card.img[41*128+i]=card.img[40*128+i];card.img[40*128+i]=0;end
    card.img[40*128]=32'he5000000;
   end
   default:begin end
  endcase
  repeat(4)@(negedge clk);rst_n=1;
  while(!label_ready && error_code==0 && cycles<60000020)begin @(negedge clk);cycles=cycles+1;end
  if(expected_error!=0)begin
   if(label_ready || error_code!=expected_error)$fatal(1,"FAULT scenario=%0d got=%h exp=%h",scenario,error_code,expected_error);
   $display("LOADER_FAULT_PASS scenario=%0d code=%h cycles=%0d",scenario,error_code,cycles);$finish;
  end else begin
  if(!label_ready || error_code!=0)$fatal(1,"BOOT code=%h ready=%b cycles=%0d",error_code,label_ready,cycles);
  for(i=0;i<153600;i=i+1)if(dut.u_sdram.mem[21'h40000+i]!==golden[i])$fatal(1,"WRITE_VERIFY i=%0d",i);
  read_burst(21'h40000);read_burst(21'h40138);read_burst(21'h657f8);
  if(dut.u_sdram.err_count!=0 || card.framing_err!=0)$fatal(1,"MODEL protocol errors SDRAM=%0d SPI=%0d",dut.u_sdram.err_count,card.framing_err);
  @(negedge clk);rd_req_addr=21'h40001;rd_req_valid=1;
  repeat(3)@(negedge clk);
  if(error_code!=8'h45 || label_ready)$fatal(1,"ILLEGAL_READ code=%h",error_code);
  $display("LOADER_PASS fileBytes=921654 physicalWords=153600 readBursts=3 cycles=%0d SPIreads=%0d SDRAMrefresh=%0d",cycles,card.data_tok_cnt,dut.u_sdram.ref_count);
  $finish;
  end
 end
endmodule
