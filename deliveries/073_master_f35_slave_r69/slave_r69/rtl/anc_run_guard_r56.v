`timescale 1ns/1ps
// 每次RUN独立锁存中心与模式；仅越界/配置变化/意外退出时静音，不改正常追频。
module anc_run_guard_r56(input wire clk,rst_n,clear,run,sample_valid,auto_mode,
 input wire [1:0] tone_select,input wire [31:0] center_increment,configured_increment,tracked_increment,
 input wire [13:0] center_hz,tracked_hz,
 output reg fault,output reg [2:0] fault_code,output reg [13:0] anchor_hz);
 localparam [31:0] MIN_INC=32'd3573413,MAX_INC=32'd89245984;
 reg session_seen,anchor_auto;reg [1:0] anchor_tone;
 reg [31:0] anchor_increment,anchor_configured,lower_bound,upper_bound;
 reg [13:0] lower_hz,upper_hz;reg [7:0] age;
 reg [31:0] span;
 always @*begin
  if(auto_mode)span=(center_increment>>6)<32'd446676 ? center_increment>>6 :32'd446676;
  else case(tone_select)
   0:span=32'd223338;1:span=32'd446676;2:span=32'd670014;default:span=32'd893353;
  endcase
 end
 wire [3:0] display_span=(!auto_mode&&tone_select==3) ? 4'd11 : (!auto_mode&&tone_select==2) ? 4'd9 : 4'd6;
 wire bad_configuration=center_increment!=anchor_increment||configured_increment!=anchor_configured||
  center_hz!=anchor_hz||auto_mode!=anchor_auto||tone_select!=anchor_tone;
 wire bad_increment=tracked_increment<lower_bound||tracked_increment>upper_bound;
 wire bad_display=tracked_hz<lower_hz||tracked_hz>upper_hz;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin fault<=0;fault_code<=0;session_seen<=0;anchor_hz<=0;anchor_increment<=0;anchor_configured<=0;
   anchor_auto<=0;anchor_tone<=0;lower_bound<=MIN_INC;upper_bound<=MAX_INC;lower_hz<=0;upper_hz<=0;age<=0;end
  else if(clear)begin fault<=0;fault_code<=0;session_seen<=0;age<=0;end
  else if(!fault)begin
   if(run&&!session_seen)begin
    session_seen<=1;anchor_increment<=center_increment;anchor_configured<=configured_increment;
    anchor_hz<=center_hz;anchor_auto<=auto_mode;anchor_tone<=tone_select;age<=0;
    lower_bound<=center_increment>MIN_INC+span ? center_increment-span : MIN_INC;
    upper_bound<=center_increment<MAX_INC-span ? center_increment+span : MAX_INC;
    lower_hz<=center_hz>{10'd0,display_span} ? center_hz-{10'd0,display_span} : 14'd0;upper_hz<=center_hz+{10'd0,display_span};
   end else if(session_seen)begin
    if(!run)begin fault<=1;fault_code<=4;end
    else if(bad_configuration)begin fault<=1;fault_code<=3;end
    else if(bad_increment)begin fault<=1;fault_code<=1;end
    else if(age>=128&&bad_display)begin fault<=1;fault_code<=2;end
    if(sample_valid&&age<128)age<=age+8'd1;
   end
  end
 end
endmodule
