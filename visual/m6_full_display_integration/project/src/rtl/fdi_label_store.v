`timescale 1ns/1ps
// 受控TF卡LBA64直读固定BMP、物理标签全量校验与运行期BL8只读服务。
// 文件/标签CRC共用逐bit核；不挂载文件系统，LBA2048起的PCM分区不访问。
module fdi_label_store #(
 parameter integer STARTUP_CYCLES=500000,
 parameter integer BOOT_TIMEOUT_CYCLES=500000000,
 parameter integer SERVICE_TIMEOUT_CYCLES=1000000
)(
 input wire clk,mem_clk,rst_n,input wire sd_miso,
 output wire sd_dclk,sd_mosi,sd_ncs,
 output wire label_ready,output reg [7:0] error_code,
 input wire rd_req_valid,input wire [20:0] rd_req_addr,
 output wire rd_req_ready,rd_beat_valid,
 output wire [31:0] rd_beat_data,output wire [20:0] rd_beat_addr,
 output wire rd_done
);
 localparam [20:0] LABEL_BASE=21'h40000,LABEL_END=21'h65800;
 localparam [19:0] FILE_BYTES=20'd921654;
 localparam [10:0] LAST_SECTOR=11'd1800;
 localparam BOOT=0,INIT=1,SECTOR_START=2,LOAD=3,DRAIN=4,
 CHECK_REQ=5,CHECK_WAIT=6,CHECK_FETCH=7,CHECK_WORD=8,CHECK_BITS=9,READY=10,ERROR=11;
 reg [3:0] state;
 reg [28:0] watchdog;
 localparam [28:0] START_LIMIT=STARTUP_CYCLES[28:0]-29'd1;
 localparam [28:0] BOOT_LIMIT=BOOT_TIMEOUT_CYCLES[28:0]-29'd1;
 localparam [28:0] SERVICE_LIMIT=SERVICE_TIMEOUT_CYCLES[28:0]-29'd1;
 // 复用底层调试出口不消费，显式连接以保留接口。
 /* verilator lint_off UNUSEDSIGNAL */
 wire unused_init_busy;
 wire [7:0] unused_init_r1,unused_read_r1;
 wire [31:0] unused_mem_rdata;
 /* verilator lint_on UNUSEDSIGNAL */
 // MISO恒等缓冲保留为实际LUT级，补偿PAD到CTRL捕获端的物理Hold；无新增拍。
 wire [4:0] miso_hold;
 assign miso_hold[0]=sd_miso;
 genvar miso_stage;
 generate for(miso_stage=0;miso_stage<4;miso_stage=miso_stage+1)begin:miso_hold_stage
  (* syn_keep=1, dont_touch=1 *) EG_LOGIC_BUF u_hold(.i(miso_hold[miso_stage]),.o(miso_hold[miso_stage+1]));
 end endgenerate
 reg init_start,init_ready,sector_req;
 reg [10:0] sector_number;
 wire init_done,init_error,card_sdhc;
 wire [2:0] init_code;
 wire init_cs,init_sck,init_mosi,read_cs,read_sck,read_mosi;
 fdi_sd_init_sequence #(.INIT_POLL_MAX(2048)) u_init(
  .clk(clk),.rst_n(rst_n),.init_start(init_start),.init_busy(unused_init_busy),.init_done(init_done),
  .init_error(init_error),.init_error_code(init_code),.card_is_sdhc(card_sdhc),.init_resp_r1(unused_init_r1),
  .spi_cs_n(init_cs),.spi_sck(init_sck),.spi_mosi(init_mosi),.spi_miso(miso_hold[4]),
  .spi_clk_div_slow(16'd63));
 assign sd_ncs=init_ready ? read_cs : init_cs;
 assign sd_dclk=init_ready ? read_sck : init_sck;
 assign sd_mosi=init_ready ? read_mosi : init_mosi;
 wire sector_busy,sector_valid,sector_done;
 wire [7:0] sector_byte,sector_error;
 wire [8:0] sector_index;
 wire [31:0] sector_lba=32'd64+{21'd0,sector_number};
 fdi_sd_spi_sector_reader #(.SPI_CLK_DIV(1)) u_reader(
  .clk(clk),.rst_n(rst_n),.init_ready(init_ready),.card_high_capacity(card_sdhc),
  .sector_req(sector_req),.sector_lba(sector_lba),
  .sector_busy(sector_busy),.sector_done(sector_done),.sector_valid(sector_valid),
  .sector_byte(sector_byte),.sector_byte_index(sector_index),.sector_error(sector_error),.last_r1(unused_read_r1),
  .sd_cs_n(read_cs),.sd_sclk(read_sck),.sd_mosi(read_mosi),.sd_miso(miso_hold[4]));

 // 只接受本包固定黄金文件；分辨率、行序和BGR纯截断无运行时变体。
 function [7:0] header_byte;
  input [5:0] offset;
  begin case(offset)
   0:header_byte=8'h42;1:header_byte=8'h4d;
   2,10:header_byte=8'h36;3,35:header_byte=8'h10;4,36:header_byte=8'h0e;
   14:header_byte=8'h28;18:header_byte=8'h80;19:header_byte=8'h02;
   22:header_byte=8'he0;23,26:header_byte=8'h01;28:header_byte=8'h18;
   38,42:header_byte=8'h13;39,43:header_byte=8'h0b;
   default:header_byte=8'h00;
  endcase end
 endfunction
 reg [31:0] crc_work,crc_data;
 reg [5:0] crc_bits;
 reg [1:0] byte_phase;
 reg [4:0] blue5;
 reg [5:0] green6;
 reg half_full,write_pending;
 reg [15:0] low_label;
 reg [31:0] write_data;
 reg [17:0] write_index;
 reg [19:0] bytes_seen;
 wire [15:0] decoded_label={sector_byte[7:3],green6,blue5};
 reg [20:0] check_addr;
 wire [31:0] check_word;
 reg [3:0] check_count;
 reg [2:0] check_index;
 reg mem_busy;
 wire eng_ready,eng_init,eng_resp,eng_resp_write,eng_beat;
 wire [31:0] eng_data;
 wire [20:0] eng_addr;
 // 复用已验证的同步DP9K字分片，8字读回缓存不展开为256个FF。
 fdi_state_lane u_check_buffer(.clk(clk),.rd_addr({5'd0,check_index}),.rd_data(check_word),
  .wr_clk(clk),.we(state==CHECK_WAIT && eng_beat && check_count<8),
  .wr_addr({5'd0,check_count[2:0]}),.wr_data(eng_data));
 wire ext_legal=rd_req_addr[2:0]==0 && rd_req_addr>=LABEL_BASE && rd_req_addr<=LABEL_END-8;
 wire load_write=(state==LOAD || state==DRAIN) && write_pending;
 wire check_read=state==CHECK_REQ;
 wire ext_read=state==READY && rd_req_valid && ext_legal;
 wire req_valid=!mem_busy && (load_write || check_read || ext_read);
 wire [20:0] req_addr=load_write ? LABEL_BASE+{3'd0,write_index} :
                           check_read ? check_addr : rd_req_addr;
 wire req_fire=req_valid && eng_ready;
 assign label_ready=state==READY && error_code==0;
 assign rd_req_ready=label_ready && !mem_busy && eng_ready && (!rd_req_valid || ext_legal);
 assign rd_beat_valid=label_ready && mem_busy && eng_beat;
 assign rd_beat_data=eng_data;
 assign rd_beat_addr=eng_addr;
 assign rd_done=label_ready && mem_busy && eng_resp && !eng_resp_write;
 wire refresh_req,refresh_ack;
 fdi_sdram_refresh_timer #(.REF_INTERVAL_CYCLES(781)) u_refresh(
  .clk(clk),.rst_n(rst_n),.refresh_req(refresh_req),.ref_ack(refresh_ack));
 wire sdr_cke,sdr_cs,sdr_ras,sdr_cas,sdr_we,sdr_oe;
 wire [10:0] sdr_addr;
 wire [1:0] sdr_ba;
 wire [3:0] sdr_dm;
 wire [31:0] sdr_out,sdr_in;
 reg [31:0] dq_capture;
 // 180度域捕获使读回路径具有真实FF发射点；保留既有 DQ_LAT=1。
 always @(posedge mem_clk) dq_capture<=sdr_in;
 fdi_sdram_cmd_engine #(.T_INIT(10000),.T_RP(2),.T_RCD(2),.T_WR(2),.T_MRD(2),
  .T_RFC(4),.CAS_LAT(3),.DQ_LAT(1),.BURST_LEN(8)) u_mem(
  .clk(clk),.rst_n(rst_n),.init_done(eng_init),.refresh_req(refresh_req),.refresh_ack(refresh_ack),
  .req_valid(req_valid),.req_ready(eng_ready),.req_write(load_write),.req_addr(req_addr),
  .req_wdata(write_data),.req_dm(4'd0),.resp_valid(eng_resp),.resp_write(eng_resp_write),.resp_rdata(unused_mem_rdata),
  .beat_valid(eng_beat),.beat_data(eng_data),.beat_addr(eng_addr),
  .sdr_cke(sdr_cke),.sdr_cs_n(sdr_cs),.sdr_ras_n(sdr_ras),.sdr_cas_n(sdr_cas),.sdr_we_n(sdr_we),
  .sdr_addr(sdr_addr),.sdr_ba(sdr_ba),.sdr_dm(sdr_dm),.sdr_dq_out(sdr_out),.sdr_dq_oe(sdr_oe),.sdr_dq_in(dq_capture));
 EG_PHY_SDRAM_2M_32 u_sdram(
  .clk(mem_clk),.cke(sdr_cke),.cs_n(sdr_cs),.ras_n(sdr_ras),.cas_n(sdr_cas),.we_n(sdr_we),
  .addr(sdr_addr),.ba(sdr_ba),.dm0(sdr_dm[0]),.dm1(sdr_dm[1]),.dm2(sdr_dm[2]),.dm3(sdr_dm[3]),.dq(sdr_in));
 assign sdr_in=sdr_oe ? sdr_out : 32'bz;
 task fail;
  input [7:0] code;
  begin error_code<=code;state<=ERROR;end
 endtask
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin
   state<=BOOT;error_code<=0;watchdog<=0;init_start<=0;init_ready<=0;sector_req<=0;sector_number<=0;
   crc_work<=32'hffffffff;crc_data<=0;crc_bits<=0;byte_phase<=0;blue5<=0;green6<=0;
   half_full<=0;write_pending<=0;low_label<=0;write_data<=0;write_index<=0;bytes_seen<=0;
   check_addr<=LABEL_BASE;check_count<=0;check_index<=0;mem_busy<=0;
  end else begin
   init_start<=0;sector_req<=0;
   if(req_fire)begin
    mem_busy<=1;
    if(load_write)begin write_pending<=0;write_index<=write_index+1'b1;end
   end
   if(eng_resp)mem_busy<=0;
   if(crc_bits!=0)begin
    crc_work<=(crc_work>>1)^((crc_work[0]^crc_data[0]) ? 32'hedb88320 : 32'd0);
    crc_data<=crc_data>>1;crc_bits<=crc_bits-1'b1;
   end
   if(state==LOAD && sector_valid && bytes_seen<FILE_BYTES)begin
    if(crc_bits!=0 || sector_index!=bytes_seen[8:0])fail(8'h43);
    else begin crc_work<=crc_work^{24'd0,sector_byte};
     // XOR byte后逐bit只移CRC；crc_data置0避免重复异或输入。
     crc_data<=0;crc_bits<=8;bytes_seen<=bytes_seen+1'b1;
    end
    if(bytes_seen<54)begin if(sector_byte!=header_byte(bytes_seen[5:0]))fail(8'h40);end
    else begin
     case(byte_phase)
      0:begin blue5<=sector_byte[7:3];byte_phase<=1;end
      1:begin green6<=sector_byte[7:2];byte_phase<=2;end
      default:begin
       byte_phase<=0;half_full<=!half_full;
       if(!half_full)low_label<=decoded_label;
       else if(write_pending)fail(8'h43);
       else begin write_data<={decoded_label,low_label};write_pending<=1;end
      end
     endcase
    end
   end
   if(state==CHECK_WAIT && eng_beat)begin
    if(check_count==8)fail(8'h49);
    else check_count<=check_count+1'b1;
   end
   case(state)
    BOOT:if(watchdog==START_LIMIT)begin init_start<=1;state<=INIT;end
    INIT:if(init_error)fail({5'b10000,init_code});
     else if(init_done)begin init_ready<=1;state<=SECTOR_START;end
    SECTOR_START:if(eng_init && !sector_busy)begin sector_req<=1;state<=LOAD;end
    LOAD:if(sector_done)begin
     if(sector_error!=0)fail(sector_error);
     else if(sector_number==LAST_SECTOR)state<=DRAIN;
     else begin sector_number<=sector_number+1'b1;state<=SECTOR_START;end
    end
    DRAIN:if(!write_pending && !mem_busy && crc_bits==0)begin
     if(bytes_seen!=FILE_BYTES || write_index!=153600 || byte_phase!=0 || half_full)fail(8'h42);
     else if((crc_work^32'hffffffff)!=32'h47e2a01d)fail(8'h41);
     else begin crc_work<=32'hffffffff;check_addr<=LABEL_BASE;state<=CHECK_REQ;end
    end
    CHECK_REQ:if(req_fire)begin check_count<=0;check_index<=0;state<=CHECK_WAIT;end
    CHECK_WAIT:if(eng_resp)begin
     if(eng_resp_write || check_count!=8)fail(8'h49);else state<=CHECK_FETCH;
    end
    CHECK_FETCH:state<=CHECK_WORD;
    CHECK_WORD:begin crc_data<=check_word;crc_bits<=32;state<=CHECK_BITS;end
    CHECK_BITS:if(crc_bits==0)begin
     if(check_index!=7)begin check_index<=check_index+1'b1;state<=CHECK_FETCH;end
     else if(check_addr==LABEL_END-8)begin
      if((crc_work^32'hffffffff)!=32'ha1e4d4e1)fail(8'h48);else begin state<=READY;watchdog<=0;end
     end else begin check_addr<=check_addr+8;state<=CHECK_REQ;end
    end
    READY:if(rd_req_valid && !ext_legal)fail(8'h45);
    ERROR:begin end
    default:fail(8'h49);
   endcase
   if(state!=READY && state!=ERROR)begin
    watchdog<=watchdog+1'b1;
    if(watchdog==BOOT_LIMIT)fail(8'h46);
   end else if(state==READY)begin
    if(!mem_busy || eng_resp)watchdog<=0;
    else begin watchdog<=watchdog+1'b1;if(watchdog==SERVICE_LIMIT)fail(8'h47);end
   end
  end
 end
endmodule
