`timescale 1ps/1ps
// 经真实按键中止被拔卡打断的事务；用独立整帧黄金核验恢复和后续翻页。
module tb_output_route;
    reg clk=0,rst_n=0;
    always #10000 clk=~clk;
    reg [3:0] sw=0;
    reg k2=1,k3=1,k4=1;
    wire sd_clk,sd_cmd; wire [3:0] sd_dat;
    pullup(sd_cmd);pullup(sd_dat[0]);pullup(sd_dat[1]);pullup(sd_dat[2]);pullup(sd_dat[3]);
    sd_card_model #(.ACMD41_BUSY(1),.NAC_MAX(20)) card(.sd_clk(sd_clk),.sd_cmd(sd_cmd),.sd_dat(sd_dat));
    t073_board_pin_top #(.MS_CYCLES(500),.SEC_CYCLES(32'd50_000_000),.ACMD41_TRIES(100),.TRANS_FRAMES(4)) dut(
        .clk_50m(clk),.rst_n(rst_n),.sw(sw),.key2_n(k2),.key3_n(k3),.key4_n(k4),
        .c1_rx_data(1'b1),.c1_tx_data(),.c1_d3_low(),.c1_e3_low(),.c1_e4_low(),.c1_k1_low(),.c1_j1_low(),.c1_f4_low(),
        .sd_clk(sd_clk),.sd_cmd(sd_cmd),.sd_dat(sd_dat),.HDMI_CLK_P(),.HDMI_D0_P(),.HDMI_D1_P(),.HDMI_D2_P(),
        .HDMI_DDC_SCL(),.HDMI_DDC_SDA(),.led());
    longint unsigned hashes[0:47], hash;
    int labels[0:47], ng=0, pixels=0, frames=0, last_label=-2, shows=0;
    string fault;
    event frame_done;
    reg [15:0] wav_golden[0:35999], video_golden[0:6409];
    initial begin
        $readmemh("sim/f0_wav.hex",wav_golden);
        $readmemh("sim/f0_vaud.hex",video_golden);
    end
    initial begin
        int fd,label;string name;longint unsigned value;
        fd=$fopen("sim/f0_hash.txt","r");if(!fd)$fatal(1,"missing golden");
        while(ng<48 && $fscanf(fd,"%s %h %d",name,value,label)==3)begin hashes[ng]=value;labels[ng]=label;ng++;end
        $fclose(fd);
    end
    always @(posedge clk) if(dut.u_core.show_req)shows++;
    always @(posedge dut.u_core.pixel_clk) begin
        if(!dut.u_core.u_vmem.o_vs)begin pixels=0;hash=64'hcbf29ce484222325;end
        else if(dut.u_core.u_vmem.o_de)begin
            hash=(hash^{48'd0,dut.u_core.u_vmem.o_rgb565})*64'h100000001b3;pixels++;
            if(pixels==307200)begin
                last_label=-1;for(int i=0;i<ng;i++)if(last_label==-1 && hash==hashes[i])last_label=labels[i];
                frames++; ->frame_done;
            end
        end
    end
    task automatic press(input int key,input bit long_hold);
        @(negedge clk);if(key==2)k2=0;else if(key==3)k3=0;else k4=0;
        if(long_hold)#(64'd12*1000000000);else #(64'd1*1000000000);
        if(key==2)k2=1;else if(key==3)k3=1;else k4=1;
        #(64'd1*1000000000);
    endtask
    task automatic expect_audio(input bit video_audio);
        reg [15:0] window[0:3];
        int count,cycles,offset,limit;bit match;
        count=0;cycles=0;offset=-1;limit=video_audio ? 6410 : 36000;
        while(count<4 && cycles<6000000)begin
            @(posedge dut.u_core.pixel_clk);cycles++;
            if(dut.u_core.au_valid && (count!=0 || dut.u_core.au_left!=0))begin window[count]=dut.u_core.au_left[23:8];count++;end
        end
        if(count!=4)begin $display("RESULT FAIL no resumed audio");$finish;end
        for(int i=0;i<limit-3;i++)begin
            match=1;
            for(int k=0;k<4;k++)if(window[k]!=(video_audio ? video_golden[i+k] : wav_golden[i+k]))match=0;
            if(match && offset<0)offset=i+4;
        end
        if(offset<0)begin $display("RESULT FAIL resumed audio not in independent golden");$finish;end
        count=0;cycles=0;
        while(count<256 && cycles<6000000)begin
            @(posedge dut.u_core.pixel_clk);cycles++;
            if(dut.u_core.au_valid)begin
                if(dut.u_core.au_left[23:8]!=(video_audio ? video_golden[offset%limit] : wav_golden[offset%limit]) || dut.u_core.au_right!=dut.u_core.au_left)begin
                    $display("RESULT FAIL resumed audio mismatch sample=%0d",offset);$finish;
                end
                offset++;count++;
            end
        end
        if(count!=256)begin $display("RESULT FAIL resumed audio cadence stopped");$finish;end
        $display("STEP resumed audio golden samples=%0d video=%0d",count+4,video_audio);$fflush();
    endtask
    task automatic expect_frame(input int label,input int budget,input string phase_name);
        int hits;hits=0;
        repeat(budget)begin
            @(frame_done);
            if(last_label==label)hits++;else hits=0;
            if(hits==2)begin $display("STEP %s label=%0d frames=%0d",phase_name,label,frames);$fflush();return;end
        end
        $display("RESULT FAIL %s label=%0d ms=%0d fx=%0d init_count=%0d",phase_name,last_label,dut.u_core.u_mc.ms,dut.u_core.u_mc.fx,card.init_count);
        $finish;
    endtask
    int reset_count=0, reset_memory_budget=0;
    always @(negedge dut.u_core.system_rst_n) if(rst_n) begin
        reset_count++;
        // 每次完整复位丢弃旧RAM内容；最多一个刷新超期及每个原活动bank一次tRAS max。
        reset_memory_budget++;
        for(int bank=0;bank<4;bank++) if(dut.u_core.u_vmem.u_sdram.bank_active[bank]) reset_memory_budget++;
        $display("PHASE FULL_RESET_BEGIN cause=KEY3");$fflush();
    end
    always @(negedge dut.u_core.system_rst_n) if(rst_n) begin
        wait(dut.u_core.system_rst_n && dut.u_core.u_vmem.init_done);
        $display("PHASE FULL_RESET_REINITIALIZED cause=KEY3");$fflush();
    end
    task automatic step_menu(input int target);
        int g;g=0;
        while(dut.u_core.m_focus!=target && g<8)begin press(2,0);g++;end
        if(dut.u_core.m_focus!=target)$fatal(1,"menu target");
    endtask
    task automatic route_check(input int mode,input string label);
        int n,nz,pre_nz,cycles;n=0;nz=0;pre_nz=0;cycles=0;
        while(n<512 && cycles<2000000)begin
            @(posedge dut.u_core.pixel_clk);cycles++;
            if(dut.u_core.playback_frame_valid && dut.u_core.playback_frame_sample!=0)pre_nz++;
            if(dut.u_core.au_valid)begin
                n++;if(dut.u_core.au_left!=0)nz++;
                if(dut.u_core.u_c1.audio_data!=dut.u_core.au_left[23:8] ||
                   dut.u_core.u_c1.audio_valid!=dut.u_core.au_valid)$fatal(1,"C1 PCM route");
                if(mode!=0 && (dut.u_core.u_hdmi.audio_left!=0 || dut.u_core.u_hdmi.audio_right!=0))$fatal(1,"HDMI mute route");
                if(mode==0 && (dut.u_core.u_hdmi.audio_left!=dut.u_core.au_left || dut.u_core.u_hdmi.audio_right!=dut.u_core.au_right))$fatal(1,"HDMI enabled route");
            end
        end
        if(n!=512 || pre_nz<100 || (mode==2 ? nz!=0 : nz<100))$fatal(1,"route coverage %s n=%0d nz=%0d pre=%0d",label,n,nz,pre_nz);
        $display("STEP ROUTE %s n=%0d source_nonzero=%0d before_gain_nonzero=%0d",label,n,nz,pre_nz);$fflush();
    endtask
    initial begin
        #(200*1000000);rst_n=1;wait(!dut.u_core.u_mc.boot_pend);
        sw=4'b0010;repeat(2)@(frame_done);press(2,0);
        wait(dut.u_core.wav_selected && dut.u_core.wav_hdr);
        expect_audio(0);route_check(0,"HDMI+SPK");
        sw[0]=1;repeat(2)@(frame_done);step_menu(6);press(4,0);repeat(2)@(frame_done);
        if(!dut.u_core.m_spk)$fatal(1,"OUTPUT SPK ONLY state");
        route_check(1,"SPK ONLY C1 continues HDMI zero");
        step_menu(1);repeat(20)press(3,0);repeat(8)@(frame_done);
        if(dut.u_core.m_volume!=0)$fatal(1,"VOLUME zero state");
        route_check(2,"VOLUME zero both routes zero");
        repeat(20)press(4,0);repeat(8)@(frame_done);
        route_check(1,"VOLUME restored C1 resumes");
        step_menu(6);press(3,0);repeat(2)@(frame_done);
        route_check(0,"HDMI+SPK restored");
        $display("RESULT PASS real physical keys audio volume and output routing");$finish;
    end
    initial begin #(64'd3000*1000000000);$display("RESULT FAIL global timeout");$finish;end
endmodule
