`timescale 1ns/1ps
module tb_gain_all;
 reg clk=0,rst=1,sv=0;always #10 clk=~clk;
 reg signed[15:0]sample;reg[4:0]volume;wire valid,busy;wire signed[15:0]out;
 wm_audio_gain dut(.clk(clk),.rst(rst),.sample_valid(sv),.sample(sample),.volume_steps(volume),.valid(valid),.scaled(out),.busy(busy));
 int checked=0;
 initial begin
  repeat(4)@(negedge clk);rst=0;
  for(int v=0;v<=20;v++)for(int n=-32768;n<=32767;n++)begin
   int p,expected,guard;p=n*v;expected=(p<0)?-((-p+19)/20):p/20;
   @(negedge clk);sample=n;volume=v;sv=1;@(negedge clk);sv=0;guard=0;
   while(!valid&&guard<24)begin @(negedge clk);guard++;end
   if(!valid||$signed(out)!=expected)$fatal(1,"gain n=%0d v=%0d out=%0d expected=%0d",n,v,$signed(out),expected);
   checked++;
  end
  if(checked!=1376256)$fatal(1,"empty gain coverage");
  $display("RESULT PASS gain signed16_all volumes0_20 checked=%0d",checked);$finish;
 end
endmodule
