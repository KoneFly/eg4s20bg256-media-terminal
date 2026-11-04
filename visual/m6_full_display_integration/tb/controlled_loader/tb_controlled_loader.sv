`timescale 1ns/1ps
// 引脚级真SPI/SDRAM加载与实际行供给链；W2/S2冻结验证由原SSOT保持。
module tb_controlled_loader;
 reg clk=0;always #10 clk=!clk;
 reg pixel_clk=0;always #19.841 pixel_clk=!pixel_clk;
 wire mem_clk=!clk;
 reg rst_n=0,display_stage=0;
 wire sd_ncs,sd_dclk,sd_mosi,sd_miso,label_ready;
 wire [7:0] error_code;
 reg manual_req=0;
 reg [20:0] manual_addr=0;
 wire stream_req;
 wire [20:0] stream_addr;
 wire rd_req_valid=display_stage ? stream_req : manual_req;
 wire [20:0] rd_req_addr=display_stage ? stream_addr : manual_addr;
 wire rd_req_ready,rd_beat_valid,rd_done;
 wire [31:0] rd_beat_data;
 wire [20:0] rd_beat_addr;
 fdi_label_store #(.STARTUP_CYCLES(32),.BOOT_TIMEOUT_CYCLES(60000000)) dut(.*);
 sd_spi_card_model #(.IMG_SECTORS(4096)) card(
  .spi_cs_n(sd_ncs),.spi_sck(sd_dclk),.spi_mosi(sd_mosi),.spi_miso(sd_miso));
 wire pixel_ready,pixel_valid;
 wire [31:0] pixel_data;
 wire [7:0] stream_error;
 reg pixel_take=0;
 fdi_label_stream stream(.clk(clk),.rst_n(rst_n && display_stage),.label_ready(label_ready),
  .rd_req_valid(stream_req),.rd_req_addr(stream_addr),.rd_req_ready(rd_req_ready),
  .rd_beat_valid(rd_beat_valid),.rd_beat_data(rd_beat_data),.rd_beat_addr(rd_beat_addr),.rd_done(rd_done),
  .pixel_clk(pixel_clk),.pixel_rst(!display_stage),.pixel_take(pixel_take),
  .pixel_ready(pixel_ready),.pixel_data(pixel_data),.pixel_valid(pixel_valid),.error_code(stream_error));
 reg [31:0] golden[0:153599];
 integer cycles=0,beats=0,i,scenario=0,cmd_reads=0;
 integer px=0,py=0,h=0,v=0,pixels=0,word_index=0;
 reg started=0,corruption_applied=0;
 reg [7:0] expected_error=0;
 reg [15:0] expected_pixel;
 always @(negedge clk)begin
  if(scenario==3 && !corruption_applied && dut.state==dut.CHECK_REQ)begin
   dut.u_sdram.mem[21'h40064]=dut.u_sdram.mem[21'h40064]^32'd1;
   corruption_applied=1;
  end
 end
 always @(posedge clk)if(rst_n && rd_beat_valid)begin
  if(rd_beat_addr<21'h40000 || rd_beat_addr>=21'h65800)$fatal(1,"READ_ADDR %h",rd_beat_addr);
  if(rd_beat_data!==golden[rd_beat_addr-21'h40000])$fatal(1,"READ_DATA addr=%h",rd_beat_addr);
  beats=beats+1;
 end
 always @(negedge pixel_clk)if(display_stage)begin
  if(!started && pixel_ready)started=1;
  pixel_take=started && h>=144 && h<784 && v>=33 && v<513;
  if(h==799)begin h=0;if(v==524)v=0;else v=v+1;end else h=h+1;
  if(pixel_valid)begin
   word_index=((479-py)*640+px)/2;
   expected_pixel=px[0] ? golden[word_index][31:16] : golden[word_index][15:0];
   if(py>=451)expected_pixel=0;
   if(pixel_data!={expected_pixel,16'd0})$fatal(1,"PIXEL x=%0d y=%0d actual=%h exp=%h",px,py,pixel_data,expected_pixel);
   pixels=pixels+1;
   if(px==639)begin px=0;py=py+1;end else px=px+1;
  end
  if(error_code || stream_error)$fatal(1,"STREAM_FAIL store=%h stream=%h",error_code,stream_error);
 end
 task read_burst;
  input [20:0] a;
  begin
   @(negedge clk);beats=0;manual_addr=a;manual_req=1;
   while(!rd_req_ready)@(negedge clk);
   @(negedge clk);manual_req=0;
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
   1:begin card.img[(64*512+100)/4]^=32'h01000000;expected_error=8'h41;end
   2:begin card.img[(64*512+18)/4]^=32'h00000100;expected_error=8'h40;end
   3:expected_error=8'h48;
   4:begin card.img[64*128]=0;expected_error=8'h40;end
   5:begin card.cfg_crc_bad_lba=64;expected_error=8'h05;end
   6:begin card.cfg_dead=1;expected_error=8'h83;end
   7:card.cfg_data_filler=12;
   8:begin card.cfg_crc_bad_lba=1864;expected_error=8'h05;end
   default:begin end
  endcase
  repeat(4)@(negedge clk);rst_n=1;
  while(!label_ready && error_code==0 && cycles<60000020)begin @(negedge clk);cycles=cycles+1;end
  if(expected_error!=0)begin
   if(label_ready || error_code!=expected_error)$fatal(1,"FAULT scenario=%0d got=%h exp=%h",scenario,error_code,expected_error);
   $display("RAW_FAULT_PASS scenario=%0d code=%h cycles=%0d",scenario,error_code,cycles);$finish;
  end else begin
  if(!label_ready || error_code!=0)$fatal(1,"BOOT code=%h cycles=%0d",error_code,cycles);
  for(i=0;i<153600;i=i+1)if(dut.u_sdram.mem[21'h40000+i]!==golden[i])$fatal(1,"WRITE_VERIFY i=%0d",i);
  for(i=0;i<card.tr_cnt;i=i+1)if(card.tr_cmd[i]==17)begin
   if(card.tr_arg[i]!=64+cmd_reads)$fatal(1,"LBA_ORDER got=%0d exp=%0d",card.tr_arg[i],64+cmd_reads);
   cmd_reads=cmd_reads+1;
  end
  if(cmd_reads!=1801)$fatal(1,"LBA_COUNT %0d",cmd_reads);
  read_burst(21'h40000);read_burst(21'h40138);read_burst(21'h657f8);
  if(scenario==0 || scenario==7)begin
   @(negedge clk);display_stage=1;
   while(pixels<307200 && error_code==0)@(negedge clk);
   $display("RAW_STREAM_PASS pixels=%0d SPIreads=%0d refresh=%0d",pixels,cmd_reads,dut.u_sdram.ref_count);
  end else begin
   @(negedge clk);manual_addr=scenario==9 ? 21'h40001 : 21'h65800;manual_req=1;
   repeat(3)@(negedge clk);
   if(error_code!=8'h45 || label_ready)$fatal(1,"ILLEGAL_READ code=%h",error_code);
  end
  if(dut.u_sdram.err_count!=0 || card.framing_err!=0)$fatal(1,"MODEL protocol errors SDRAM=%0d SPI=%0d",dut.u_sdram.err_count,card.framing_err);
  $display("RAW_LOADER_PASS scenario=%0d bytes=921654 words=153600 boot_cycles=%0d",scenario,cycles);
  $finish;
  end
 end
 initial begin #1400000000;$fatal(1,"TEST_TIMEOUT");end
endmodule
