`timescale 1ns/1ps
module tb_menu_board;
 reg clk=0,rst_n=0;always #10 clk=~clk;
 reg[3:0] sw=0;reg[2:0] physical_n=3'b111;
 wire[2:0] ks,kl;wire[3:0] swq;wire[1:0]page,tgt;
 t073_panel #(.MS_CYCLES(10)) panel(.clk(clk),.rst_n(rst_n),.sw(sw),
 .keys_n({physical_n[2],physical_n[1],physical_n[0]}),.sw_q(swq),.page(page),.tgt_mode(tgt),.k_short(ks),.k_long(kl));
 wire[2:0]focus,trans,cfg;wire music,info,spk;wire[4:0]vol;wire[5:0]period;wire[1:0]spec;
 t073_menu menu(.clk(clk),.rst_n(rst_n),.active(page==3),.k_short(ks),.k_long(kl),.music_toggle(page==1 && ks[0]),.focus(focus),.music_on(music),.volume(vol),.trans_sel(trans),.period_s(period),.spec_sel(spec),.info_on(info),.spk_only(spk),.trans_cfg(cfg));
 int reloads=0,shorts=0,longs=0,checked=0;
 always @(posedge clk)begin if(kl[1]&&page!=3)reloads++;if(ks!=0)shorts++;if(kl!=0)longs++;end
 task automatic press(input int key,input bit hold_long);
  @(negedge clk);physical_n[key-2]=0;
  if(hold_long)repeat(11000)@(negedge clk);else repeat(1000)@(negedge clk);
  physical_n[key-2]=1;repeat(1000)@(negedge clk);
 endtask
 task automatic focus_to(input int n);
  int g;g=0;while(focus!=n&&g<8)begin press(2,0);g++;end
  if(focus!=n)$fatal(1,"focus");
 endtask
 task automatic defaults_check;
  if(music||vol!=20||trans||period!=3||spec||info||spk||focus)$fatal(1,"defaults");
  checked++;
 endtask
 initial begin
  repeat(10)@(negedge clk);rst_n=1;repeat(1000)@(negedge clk);defaults_check();
  for(int i=0;i<16;i++)begin
   sw=i;repeat(1000)@(negedge clk);
   if(page!=(i[0]?3:i[2]?2:i[1]?1:0)||tgt!=(i[2]?2:i[1]?1:0))$fatal(1,"SW priority %0d",i);
   checked++;
  end
  sw=1;repeat(1000)@(negedge clk);
  for(int i=1;i<=7;i++)begin press(2,0);if(focus!=i%7)$fatal(1,"focus forward");checked++;end
  press(2,1);if(focus!=6)$fatal(1,"focus backward wrap");press(2,0);
  press(4,0);if(!music)$fatal(1,"music ON");press(3,0);if(music)$fatal(1,"music OFF");
  focus_to(1);repeat(25)press(3,0);if(vol!=0)$fatal(1,"volume low");
  repeat(25)press(4,0);if(vol!=20)$fatal(1,"volume high");checked+=2;
  focus_to(2);
  for(int i=1;i<=10;i++)begin press(4,0);if(trans!=i%5)$fatal(1,"transition cycle");checked++;end
  press(3,0);if(trans!=4||cfg!=7)$fatal(1,"transition backward wrap");
  focus_to(3);repeat(65)press(4,0);if(period!=60)$fatal(1,"period high");
  repeat(65)press(3,0);if(period!=0)$fatal(1,"period low");checked+=2;
  focus_to(4);
  for(int i=1;i<=6;i++)begin press(4,0);if(spec!=i%3)$fatal(1,"spectrum cycle");checked++;end
  press(3,0);if(spec!=2)$fatal(1,"spectrum reverse");
  focus_to(5);press(4,0);if(!info)$fatal(1,"info ON");press(3,0);if(info)$fatal(1,"info OFF");
  focus_to(6);press(4,0);if(!spk)$fatal(1,"output SPK");press(3,0);if(spk)$fatal(1,"output HDMI");
  press(3,1);defaults_check();if(reloads)$fatal(1,"menu long K3 rebooted");
  sw=0;repeat(1000)@(negedge clk);press(3,1);if(reloads!=1)$fatal(1,"physical K3 did not reload");
  press(4,1);if(reloads!=1)$fatal(1,"physical K4 reloaded");
  begin
   int old_shorts,old_longs;old_shorts=shorts;old_longs=longs;
   physical_n[0]=0;repeat(1000)@(negedge clk);sw=2;repeat(1000)@(negedge clk);
   physical_n[0]=1;repeat(1000)@(negedge clk);
   if(shorts!=old_shorts||longs!=old_longs)$fatal(1,"gesture crossed page");
  end
  $display("RESULT PASS all16_SW priorities physical menu bounds checked=%0d reloads=%0d",checked,reloads);$finish;
 end
endmodule

