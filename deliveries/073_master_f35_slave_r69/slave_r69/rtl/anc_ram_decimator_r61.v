`timescale 1ns/1ps
// 双麦63tap Q15/4抽取：打包同步RAM存历史，一颗DOT乘法器轮流处理两麦。
// ready前不消费原生帧；上层必须同样等待ready再启动输出队列的帧时间戳。
module anc_ram_decimator_r61(input wire clk,rst_n,start,enable,pcm_valid,
 input wire signed [15:0] mic0,mic1,output wire ready,
 output reg valid,output reg signed [15:0] sample0,sample1,
 output reg [1:0] clipped,output reg overlap);
`include "decimator_coefficients.vh"
 localparam [2:0] IDLE=0,START0=1,WAIT0=2,START1=3,WAIT1=4;
 reg [2:0] state;reg [1:0] phase;reg [5:0] head;
 wire accept=enable&&pcm_valid&&ready;
 wire ram_valid,ram_error;wire [31:0] ram_data;
 wire dot_ready,read_enable,dot_valid,dot_bad,dot_overrun;wire [7:0] read_index,context_out;
 wire signed [63:0] sum;reg signed [17:0] coef_q;
 wire signed [17:0] value=state==WAIT1?{{2{ram_data[31]}},ram_data[31:16]}:{{2{ram_data[15]}},ram_data[15:0]};
 wire [5:0] history_address=head+read_index[5:0];
 wire [5:0] write_address=head-6'd1;
 anc_work_ram_r61 #(.WIDTH(32),.ADDR_BITS(6)) history(.clk(clk),.rst_n(rst_n),.clear(start),.write_request(accept),.write_address(write_address),.write_data({mic1,mic0}),.read_request(read_enable),.read_address(history_address),.ready(ready),.read_valid(ram_valid),.read_data(ram_data),.access_error(ram_error));
 wire signed [15:0] coefficient_value=coefficient(read_index[5:0]);
 always @(posedge clk)if(read_enable)coef_q<={{2{coefficient_value[15]}},coefficient_value};
 anc_dot18_engine_r61 engine(.clk(clk),.rst_n(rst_n),.clear(start||!enable),.request(state==START0||state==START1),.length(9'd63),.context_id(state==START1?8'd1:8'd0),.ready(dot_ready),.read_enable(read_enable),.read_index(read_index),.coefficient(coef_q),.data(value),.valid(dot_valid),.invalid_length(dot_bad),.overrun(dot_overrun),.sum(sum),.result_context(context_out));
 wire signed [63:0] rounded=sum>=0?(sum+64'sd16384)>>>15:-(((-sum)+64'sd16384)>>>15);
 wire outside=rounded>32767||rounded< -32768;
 wire signed [15:0] saturated=rounded>32767?16'sd32767:rounded< -32768?-16'sd32768:rounded[15:0];
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;phase<=0;head<=0;valid<=0;sample0<=0;sample1<=0;clipped<=0;overlap<=0;end
  else if(start)begin state<=IDLE;phase<=0;head<=0;valid<=0;sample0<=0;sample1<=0;clipped<=0;overlap<=0;end
  else begin
   valid<=0;
   if(!enable)state<=IDLE;
   else begin
    if(accept)begin head<=write_address;phase<=phase+2'd1;if(state!=IDLE)overlap<=1;else if(phase==3)state<=START0;end
    if(ram_error||dot_bad||dot_overrun)overlap<=1;
    case(state)
     START0:if(dot_ready)state<=WAIT0;
     WAIT0:if(dot_valid)begin if(context_out!=0)overlap<=1;sample0<=saturated;clipped[0]<=outside;state<=START1;end
     START1:if(dot_ready)state<=WAIT1;
     WAIT1:if(dot_valid)begin if(context_out!=1)overlap<=1;sample1<=saturated;clipped[1]<=outside;valid<=1;state<=IDLE;end
     default:begin end
    endcase
   end
  end
 end
endmodule
