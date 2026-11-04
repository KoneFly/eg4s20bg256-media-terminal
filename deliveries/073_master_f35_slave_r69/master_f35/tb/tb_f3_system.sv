`timescale 1ps / 1ps
// F3 整板系统台: 真实 t073_master_top(PLL/HDMI 发送端为仿真替身) + SD 卡模型 + 严格 SDRAM 模型。
// 通过物理拨码/按键(消抖与长按按比例缩短)走完 F3 面板(doc/output/CONTROL_MAP_F3.md):
//   上电基础形态(测试音、无叠加) -> 图片 K2/K3 翻页 -> 设置页打开 MUSIC/INFO/TRANSITION/SPECTRUM
//   -> 音乐后台播放并在换图时继续(逐样本) -> SW3 视频(序列/伴音逐样本/音画偏差、K2 暂停、
//   K3 下一个视频跳过缺号、K4 上一个) -> 退出视频音乐续播 -> SW2 播放器页(封面+虚化背景整帧黄金、
//   K3 下一首跳过缺号) -> 图墙与缩放 -> K3 长按重载。
// 帧判定: DUT 显示输出整帧 FNV-1a 与独立黄金(tools/gen_f0)比较; 样本与独立黄金逐个比较。
module tb_f3_system;
    reg clk = 0;
    always #10000 clk = ~clk;
    reg rst_n = 0;
    reg [3:0] sw = 4'b0000;
    reg key2_n = 1, key3_n = 1, key4_n = 1;

    wire sd_clk, sd_cmd;
    wire [3:0] sd_dat;
    pullup (sd_cmd);
    pullup (sd_dat[0]); pullup (sd_dat[1]); pullup (sd_dat[2]); pullup (sd_dat[3]);
    sd_card_model #(.ACMD41_BUSY(1), .NAC_MAX(20)) card (.sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_dat(sd_dat));

    wire c1_tx, hdmi_sda;
    wire [3:0] led;
    // 1 "毫秒" = 10us: 消抖 200us, 长按 10ms; 轮播 1 "秒" = 40ms
    t073_master_top #(.MS_CYCLES(500), .SEC_CYCLES(32'd2_000_000), .ACMD41_TRIES(100), .TRANS_FRAMES(4)) dut (
        .clk_50m(clk), .rst_n(rst_n), .sw(sw), .key2_n(key2_n), .key3_n(key3_n), .key4_n(key4_n),
        .c1_rx_data(1'b1), .c1_tx_data(c1_tx),
        .c1_d3_low(), .c1_e3_low(), .c1_e4_low(), .c1_k1_low(), .c1_j1_low(), .c1_f4_low(),
        .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_dat(sd_dat),
        .HDMI_CLK_P(), .HDMI_D0_P(), .HDMI_D1_P(), .HDMI_D2_P(), .HDMI_DDC_SCL(), .HDMI_DDC_SDA(hdmi_sda),
        .led(led));

    wire pclk = dut.pixel_clk;

    // ---------------- 黄金 ----------------
    localparam int NV = 6410, NW = 36000;
    reg [15:0] vaud [0:NV-1];
    reg [15:0] vaud2 [0:NV-1];
    reg [15:0] wavs [0:NW-1];
    reg [15:0] wav3 [0:NW-1];
    reg [15:0] pics [0:3*307200-1];
    longint unsigned gh [0:47];
    int              gl [0:47];
    int              ng = 0;
    initial begin
        int fd, i; string nm; longint unsigned hv;
        $readmemh("sim/f0_vaud.hex", vaud);
        $readmemh("sim/f0_wav.hex", wavs);
        $readmemh("sim/f0_vaud2.hex", vaud2);
        $readmemh("sim/f0_wav3.hex", wav3);
        $readmemh("sim/f0_pics.hex", pics);
        fd = $fopen("sim/f0_hash.txt", "r");
        if (fd == 0) begin $display("ERROR no hash file"); $finish; end
        while (ng < 48 && $fscanf(fd, "%s %h %d", nm, hv, i) == 3) begin gh[ng] = hv; gl[ng] = i; ng++; end
        $fclose(fd);
    end

    // ---------------- 帧分类 ----------------
    // 标签: 1..3 = PIC1..3, 10..13 = V0..V3, 0 = 黑, -1 = 其他(转场中间帧等)
    longint unsigned h;
    int npx = 0, frames = 0, last_label = -2, aud_at_start = 0;
    int label_q;
    function automatic int classify(longint unsigned x);
        for (int i = 0; i < ng; i++) if (x == gh[i]) return gl[i];
        return -1;
    endfunction

    // 视频检查状态
    bit   vcheck = 0;              // 处于视频稳态检查
    bit   want_black = 0;
    int   vprev = -1, vcount = 0, vseq_err = 0, vtear_err = 0, max_dev = 0, vframes_seen = 0;
    int   aidx = 0, aud_err = 0, aud_n = 0, wav_err = 0, wav_n = 0, pause_nz = 0;
    bit   in_wav = 0, in_vid = 0;
    int   cur_label = -2;
    event frame_done;

    // 幕布转场帧逐像素: 幕区必须为黑; 前半程(t<128)其余像素等于转场前的图, 后半程等于三图之一
    int curtain_frames = 0, curtain_err = 0, stable_pic = 1;
    // 与帧哈希在同一过程内按同一像素序号核对(避免两个过程对 npx 的先后竞争)
    task automatic curtain_check();
        int y, t, v, hh; bit band; reg [15:0] px;
        y = npx / 640; t = dut.u_vmem.u_scan.desc[10:3];
        v = (t < 128) ? t : 255 - t; hh = (v * 15) >> 3;
        band = (y < hh) || (y >= 480 - hh);
        px = dut.u_vmem.o_rgb565;
        if (npx == 0) curtain_frames++;
        if (band) begin if (px != 16'd0) curtain_err++; end
        else if (t < 128) begin if (px != pics[(stable_pic - 1) * 307200 + npx]) curtain_err++; end
        else if (px != pics[npx] && px != pics[307200 + npx] && px != pics[614400 + npx]) curtain_err++;
    endtask

    always @(posedge pclk) begin
        if (!dut.u_vmem.o_vs) begin npx = 0; h = 64'hcbf29ce484222325; end
        else if (dut.u_vmem.o_de) begin
            if (npx == 0) aud_at_start = aidx;
            if (dut.u_vmem.u_scan.b_use && dut.u_vmem.u_scan.desc[2:0] == 3'd4) curtain_check();
            h = (h ^ {48'd0, dut.u_vmem.o_rgb565}) * 64'h100000001b3;
            npx++;
            if (npx == 307200) begin
                int l; l = classify(h);
                frames++; cur_label = l;
                if (l >= 1 && l <= 3) stable_pic = l;
                if (vcheck && want_black) begin
                    if (l == 0) want_black = 0;
                end else if (vcheck) begin
                    if ((l >= 10 && l <= 13) || (l >= 40 && l <= 43)) begin
                        int k; k = (l >= 40) ? l - 40 : l - 10;
                        if (vprev < 0) begin
                            if (k != 0) begin vseq_err++; $display("ERROR video first frame V%0d (expect V0) @%0t", k, $time); end
                            vcount = 0;
                        end else if (k != vprev) begin
                            if (k != (vprev + 1) % 4) begin vseq_err++; $display("ERROR video seq V%0d -> V%0d @%0t", vprev, k, $time); end
                            vcount++;
                        end
                        if (vprev < 0 || k != vprev) begin
                            // 音画偏差: 第 vcount 帧上屏时已播样本数应为 vcount * 48076.923/30
                            int dev; dev = aud_at_start - (vcount * 1602564 + 500) / 1000;
                            if (vcount < 3) $display("AVDEV frame %0d audio_idx %0d dev %0d @%0t ns", vcount, aud_at_start, dev, $time/1000);
                            if (dev < 0) dev = -dev;
                            if (dev > max_dev) max_dev = dev;
                        end
                        vprev = k; vframes_seen++;
                    end else if (l != 0 && vprev >= 0) begin
                        vtear_err++; $display("ERROR video phase frame label %0d @%0t", l, $time);
                    end
                end
                ->frame_done;
            end
        end
    end

    // ---------------- 样本检查 ----------------
    // 视频伴音: 按当前片(1/2)逐样本; 音乐: 按当前曲目(0=WAV1, 2=WAV3), 续播时允许按块跳过,
    //   但样本必须是同一曲目中严格递增位置的连续段(不重复、不乱序、不夹杂别的曲目)。
    reg flush_d = 0, vclr_d = 0;
    int vsel = 1;                    // 当前视频片 1 / 2
    int wpos = -1, wtrk = 0, wav_seg = 0, wav_skip = 0;
    int tone_n = 0, wav_stall = 0;
    function automatic int wav_find(input int trk, input int from, input reg [15:0] v);
        for (int i = from; i < NW; i++) if ((trk == 2 ? wav3[i] : wavs[i]) === v) return i;
        return -1;
    endfunction
    bit wnew = 0;
    always @(posedge clk) if (dut.wav_start) wnew = 1;
    always @(posedge pclk) begin
        if (wnew) begin wnew = 0; wpos = -1; wtrk = dut.wav_slot; end
        flush_d <= dut.media_flush;
        if (dut.media_flush && !flush_d) aidx = 0;
        if (dut.u_vmem.vclr_q && !vclr_d && vcheck) begin vprev = -1; want_black = 1; end
        vclr_d <= dut.u_vmem.vclr_q;
        if (dut.u_asink.pcm_valid) begin
            if (dut.u_asink.pause_sync[1]) begin
                if (dut.u_asink.pcm != 16'd0) pause_nz++;
            end else if (in_vid) begin
                if (dut.u_asink.pcm !== (vsel == 2 ? vaud2[aidx % NV] : vaud[aidx % NV])) begin
                    if (aud_err < 5) $display("ERROR vaud%0d[%0d] got %h @%0t", vsel, aidx, dut.u_asink.pcm, $time);
                    aud_err++;
                end
                aidx++; aud_n++;
            end else if (in_wav) begin
                reg [15:0] v; int k; v = dut.u_asink.pcm;
                if (wpos >= 0 && wpos + 1 < NW && (wtrk == 2 ? wav3[wpos + 1] : wavs[wpos + 1]) === v) wpos = wpos + 1;
                else if (wpos >= 0 && (wtrk == 2 ? wav3[wpos] : wavs[wpos]) === v) wav_stall++;   // 欠载重复样本
                else begin
                    // 新段: 只能在同曲目更靠后的位置(续播/块边界)或新曲目开头
                    k = wav_find(wtrk, wpos + 1, v);
                    if (k < 0) begin
                        if (wav_err < 5) $display("ERROR wav trk%0d after %0d got %h @%0t", wtrk, wpos, v, $time);
                        wav_err++;
                    end else begin
                        if (wpos >= 0) wav_skip += k - wpos - 1;
                        wpos = k; wav_seg++;
                    end
                end
                wav_n++;
            end
        end
    end

    // ---------------- 文字层检查 ----------------
    function automatic string row_text(input int r, input int c0);
        string t; byte c;
        t = "";
        for (int k = c0; k < 64; k++) begin
            c = dut.u_osd.cram[r * 64 + k][5:0];
            if (c == 0) break;
            // 字符码: 1 空格 2..11 数字 12..37 字母 38 ':' 39 '>' 40 '-' 41 '+' 42 '<' 43 '/'
            c = (c == 1) ? 8'd32 : (c <= 11) ? 8'd46 + c : (c <= 37) ? 8'd53 + c :
                (c == 38) ? 8'd58 : (c == 39) ? 8'd62 : (c == 40) ? 8'd45 : (c == 41) ? 8'd43 : (c == 42) ? 8'd60 : 8'd47;
            t = {t, string'(c)};
        end
        return t;
    endfunction
    int errors = 0;
    // 排版器每遍约数千拍, 读文字前先等两遍刷新
    task automatic expect_row(input int r, input int c0, input string want, input string what);
        string got;
        repeat (40000) @(posedge clk);
        got = row_text(r, c0);
        if (got.len() < want.len() || got.substr(0, want.len() - 1) != want) begin
            errors++; $display("ERROR osd row %0d [%s] want prefix [%s] (%s)", r, got, want, what);
        end else $display("OSD   row %0d [%s]", r, got);
    endtask
    task automatic dump_frame(input string fn);
        int fd, n;
        fd = $fopen(fn, "w"); n = 0;
        @(negedge dut.u_vmem.o_vs);
        while (n < 307200) begin
            @(posedge pclk);
            if (dut.vo_de) begin $fwrite(fd, "%h\n", dut.composed_rgb); n++; end
        end
        $fclose(fd);
    endtask

    // ---------------- 操作 ----------------
    task automatic press(input int k, input int hold_us);
        case (k) 2: key2_n = 0; 3: key3_n = 0; 4: key4_n = 0; endcase
        #(longint'(hold_us) * 1000000);
        case (k) 2: key2_n = 1; 3: key3_n = 1; 4: key4_n = 1; endcase
        #(400 * 1000000);
    endtask
    task automatic short_press(input int k); press(k, 1000); endtask
    task automatic long_press(input int k);  press(k, 15000); endtask
    task automatic wait_label(input int want, input int timeout_ms, input string what);
        longint deadline; bit ok;
        deadline = $time + longint'(timeout_ms) * 1000000000; ok = 0;
        while (!ok && $time < deadline) begin @(frame_done); ok = (cur_label == want); end
        if (!ok) begin
            $display("ERROR timeout waiting %s (label %0d), last %0d ms=%0d mu=%0d @%0t", what, want, cur_label, dut.u_mc.ms, dut.u_mc.mu, $time);
            errors++;
        end
        $display("STEP %-30s label=%0d frames=%0d @%0t ns", what, cur_label, frames, $time / 1000);
        $fflush();
    endtask
    task automatic wait_frames(input int n); repeat (n) @(frame_done); endtask
    task automatic wait_settled(input int timeout_ms);
        longint deadline; int quiet;
        deadline = $time + longint'(timeout_ms) * 1000000000; quiet = 0;
        while (quiet < 3 && $time < deadline) begin
            @(frame_done);
            if (dut.u_mc.ms == 5'd9 && !dut.trans_busy && !dut.u_mc.bg) quiet++; else quiet = 0;
        end
    endtask
    // 翻页: 先等静止, 按键后等主控离开停留态(开始读新图), 再等新图上屏且静止, 最后核对画面
    task automatic nav_press(input int k, input int want, input int timeout_ms, input string what);
        longint deadline;
        wait_settled(400);
        short_press(k);
        deadline = $time + 64'd200 * 1000000000;
        while (dut.u_mc.ms == 5'd9 && $time < deadline) @(posedge clk);
        if (dut.u_mc.ms == 5'd9) begin errors++; $display("ERROR %s: key not taken", what); end
        wait_settled(timeout_ms);
        if (cur_label != want) begin
            errors++; $display("ERROR %s: label %0d want %0d pic_idx=%0d", what, cur_label, want, dut.pic_idx);
        end
        $display("STEP %-30s label=%0d frames=%0d @%0t ns", what, cur_label, frames, $time / 1000);
    endtask
    // 设置页: 从当前焦点向下移到第 item 项
    task automatic menu_goto(input int item);
        while (dut.m_focus != item) short_press(2);
    endtask
    task automatic wait_wav(input int n, input int timeout_ms, input string what);
        longint deadline; int n0;
        n0 = wav_n; deadline = $time + longint'(timeout_ms) * 1000000000;
        while (wav_n - n0 < n && $time < deadline) #(64'd1000000);
        if (wav_n - n0 < n) begin errors++; $display("ERROR %s: only %0d samples", what, wav_n - n0); end
        $display("STEP %-30s wav_n=%0d trk=%0d pos=%0d segs=%0d @%0t ns", what, wav_n, wtrk, wpos, wav_seg, $time / 1000);
    endtask

    int same_label, tone_seen, wseg0, pic_before, trk0, trk_exp, sdram_err0, pic_trk0, pic_exp;
    int trk_cnt = 0;
    // 播放器页内每次换曲(手动或曲尾自动)记一步, 前进 +1 / 后退 -1
    always @(posedge clk) if (dut.u_mc.trk_step && dut.pg_wav) trk_cnt = trk_cnt + (dut.u_mc.trk_back ? -1 : 1);
    // 卡上只有 PIC1..3(其余缺号自动跳过): 前进/后退都在 1..3 环上走
    function automatic int ring3(input int p, input int steps);
        int r; r = (p - 1 + steps) % 3; if (r < 0) r += 3; return r + 1;
    endfunction
    reg [3:0] pic_d = 0;
    always @(posedge clk) begin
        if (dut.pic_idx != pic_d) $display("TRACE pic_idx %0d -> %0d ms=%0d nav=%b per=%0d page=%0d @%0t ns",
            pic_d, dut.pic_idx, dut.u_mc.ms, dut.u_mc.nav_pend, dut.period_s, dut.page, $time/1000);
        pic_d <= dut.pic_idx;
    end
    // 等图片页静止后, 用 K2 翻到第 n 张(1..3); 每次按键后等画面换成下一张
    task automatic goto_pic(input int n);
        int guard, want; guard = 0;
        wait_settled(800);
        while (stable_pic != n && guard < 6) begin
            want = (stable_pic % 3) + 1;
            nav_press(2, want, 600, "goto_pic step");
            guard++;
        end
        wait_frames(6);
        if (stable_pic != n) begin errors++; $display("ERROR goto_pic %0d stuck at %0d", n, stable_pic); end
    endtask
    bit boot_watch = 0;
    int boot_black = 0;
    always @(frame_done) if (boot_watch && cur_label == 0) boot_black++;
    always @(posedge pclk) if (dut.tone_valid && !dut.wav_selected && !dut.mode_video) tone_seen = tone_seen + 1;
    initial begin
        tone_seen = 0;
        #(200 * 1000000) rst_n = 1;
        // 0. 启动动画: BOOT 帧 0 -> 1 -> 末帧(= PIC1), 动画开始后到 PIC1 之间不得出现黑帧
        wait_label(60, 400, "boot animation frame 0");
        boot_watch = 1;
        wait_label(61, 200, "boot animation frame 1");
        // 1. 末帧即 PIC1, 随后在帧边界换到图片层 PIC1 (同画面): 基础形态、测试音、无叠加层
        wait_label(1, 400, "boot -> PIC1 seamless");
        wait (dut.u_mc.boot_pend == 1'b0);
        boot_watch = 0;
        if (boot_black != 0) begin errors++; $display("ERROR %0d black frames during boot handover", boot_black); end
        if (dut.mode_eff) begin errors++; $display("ERROR still in video layer after boot"); end
        if (dut.m_music || dut.m_info || dut.m_spec != 0 || dut.trans_cfg != 0 || dut.period_s != 3) begin
            errors++; $display("ERROR power-on defaults");
        end
        wait_label(2, 400, "auto 3s -> PIC2 (direct cut)");
        if (tone_seen < 100) begin errors++; $display("ERROR no test tone (%0d)", tone_seen); end
        // 2. 设置页: PERIOD OFF(关自动轮播) / INFO ON / TRANSITION AUTO
        sw[0] = 1; wait_frames(2);
        expect_row(3, 0, " SETTINGS", "menu title");
        expect_row(5, 0, " MUSIC      < OFF      >", "menu music focus");
        menu_goto(3); repeat (3) short_press(3);
        if (dut.period_s != 0) begin errors++; $display("ERROR period off %0d", dut.period_s); end
        expect_row(8, 0, " PERIOD     < OFF      >", "period off");
        long_press(2);                                  // K2 长按 = 上一项
        if (dut.m_focus != 2) begin errors++; $display("ERROR K2 long prev %0d", dut.m_focus); end
        short_press(3);                                 // TRANSITION OFF -> AUTO(减向回绕)
        if (dut.trans_cfg != 3'd7) begin errors++; $display("ERROR trans auto %0d", dut.trans_cfg); end
        menu_goto(5); short_press(4);                   // INFO ON
        sw[0] = 0;
        goto_pic(2);
        expect_row(0, 0, " PHOTO PIC 2/8 SRC 200X150 OUT 640X480 MUSIC STOP", "marquee photo");
        begin
            string mt; int n; mt = row_text(0, 0); n = mt.len();
            while (n > 0 && mt.getc(n - 1) == " ") n--;
            if (n > 52) begin errors++; $display("ERROR marquee still has trailing fields: [%s]", mt.substr(0, n - 1)); end
        end
        // 3. 图片页 K2/K3 翻页(AUTO 转场)
        nav_press(2, 3, 400, "K2 next -> PIC3 (transition)");
        nav_press(3, 2, 400, "K3 prev -> PIC2 (transition)");
        // 4. MUSIC ON: 音乐后台播放, 换图期间继续
        sw[0] = 1; menu_goto(0); short_press(4); sw[0] = 0;
        in_wav = 1;
        wait (dut.wav_selected == 1'b1);
        wait_wav(2000, 300, "music on (WAV1)");
        if (wtrk != 0) begin errors++; $display("ERROR first track %0d", wtrk); end
        wseg0 = wav_seg;
        nav_press(2, 3, 600, "K2 next -> PIC3 with music");
        nav_press(2, 1, 600, "K2 next -> PIC1 with music");
        wait_wav(1000, 300, "music continues after page turns");
        $display("STEP music segments across page turns: %0d (skip %0d samples)", wav_seg - wseg0, wav_skip);
        // 5. 视频: 音乐让位, 伴音逐样本
        vsel = 1;
        pic_before = stable_pic;
        sw[2] = 1;
        wait (dut.mode_eff == 1'b1);
        in_wav = 0; aidx = 0; in_vid = 1; vcheck = 1; vprev = -1;
        wait_label(13, 600, "SW3 video V3");
        if (dut.wav_selected) begin errors++; $display("ERROR music not parked in video"); end
        wait_label(10, 300, "video loops V0");
        expect_row(0, 0, " VIDEO RES 640X480 FPS 30 RGB332 TIME 00:0", "marquee video");
        // K2 暂停/播放
        short_press(2); wait (dut.v_paused == 1'b1); wait_frames(1);
        same_label = cur_label;
        repeat (5) begin wait_frames(1); if (cur_label != same_label) begin errors++; $display("ERROR frame changed while paused"); end end
        $display("STEP %-30s label=%0d", "K2 pause 5 frames frozen", same_label);
        short_press(2); wait (dut.v_paused == 1'b0); wait_frames(6);
        // K3 下一个视频: VID00001 缺号 -> VID00002
        short_press(3);
        wait (dut.u_vmem.vclr_q == 1'b1); vsel = 2;
        wait (dut.u_vmem.vclr_q == 1'b0); wait (want_black == 1'b0);
        wait_label(40, 600, "K3 next video -> VID00002 U0");
        if (dut.vid_idx != 4'd2) begin errors++; $display("ERROR vid_idx %0d", dut.vid_idx); end
        wait_label(42, 300, "VID00002 U2");
        // K4 上一个视频: 回到 VID00000
        short_press(4);
        wait (dut.u_vmem.vclr_q == 1'b1); vsel = 1;
        wait (dut.u_vmem.vclr_q == 1'b0); wait (want_black == 1'b0);
        wait_label(10, 900, "K4 prev video -> VID00000 V0");
        wait_label(12, 300, "VID00000 V2");
        // 6. 退出视频: 回到 PIC1, 音乐续播(同曲目更靠后的位置)
        sw[2] = 0; vcheck = 0;
        wait (dut.mode_eff == 1'b0);
        in_vid = 0; in_wav = 1;
        wait_label(pic_before, 300, "SW3 off -> picture kept");
        wseg0 = wpos;
        wait (dut.wav_selected == 1'b1);
        wait_wav(1000, 300, "music resumes after video");
        if (wtrk != 0 || wpos <= wseg0) begin errors++; $display("ERROR music resume trk %0d pos %0d (was %0d)", wtrk, wpos, wseg0); end
        // 7. SW2 播放器页: 背景就是当前图片(不合成封面/虚化); 切歌同时同向换图
        sw[1] = 1; wait_frames(3);
        wait_label(pic_before, 300, "SW2 player page (plain picture)");
        if (dut.u_osd.cram[7 * 64 + 23] != 8'd0 || dut.u_osd.cram[8 * 64 + 23] != 8'd0) begin
            errors++; $display("ERROR player still draws output/volume rows");
        end
        // 曲目可能已在曲尾自然切到下一首: 按当前曲目核对文字, K3 下一首跳过缺号(WAV2/WAV4)
        trk0 = dut.wav_slot;
        expect_row(4, 23, trk0 == 0 ? " MUSIC WAV1/4" : " MUSIC WAV3/4", "player track");
        expect_row(5, 23, "PLAY  00:0", "player time row");
        if (dut.u_osd.cram[5 * 64 + 39][5:0] == 6'd0 || dut.u_osd.cram[5 * 64 + 40][5:0] > 6'd1) begin
            errors++; $display("ERROR player time row not within col 39");
        end
        dump_frame("sim/player.hex");
        trk_exp = (trk0 == 0) ? 2 : 0;
        pic_trk0 = stable_pic; trk_cnt = 0;
        short_press(3);
        wait (dut.wav_slot == trk_exp && dut.wav_selected == 1'b1);
        wait_wav(1000, 400, "K3 next track (skip missing)");
        if (wtrk != trk_exp) begin errors++; $display("ERROR next track %0d want %0d", wtrk, trk_exp); end
        expect_row(4, 23, trk_exp == 0 ? " MUSIC WAV1/4" : " MUSIC WAV3/4", "player track after K3");
        wait_settled(600);
        pic_exp = ring3(pic_trk0, trk_cnt);
        if (trk_cnt < 1 || stable_pic != pic_exp) begin
            errors++; $display("ERROR track change did not switch picture: pic %0d -> %0d (steps %0d, want %0d)", pic_trk0, stable_pic, trk_cnt, pic_exp);
        end
        $display("STEP %-30s pic %0d -> %0d (track steps %0d)", "K3 next track -> next picture", pic_trk0, stable_pic, trk_cnt);
        // K4 上一首: 图片同时后退
        pic_trk0 = stable_pic; trk_cnt = 0;
        short_press(4);
        wait (trk_cnt != 0 && dut.wav_selected == 1'b1);
        wait_wav(500, 400, "K4 prev track");
        wait_settled(600);
        pic_exp = ring3(pic_trk0, trk_cnt);
        if (trk_cnt > -1 || stable_pic != pic_exp) begin
            errors++; $display("ERROR prev track did not step picture back: pic %0d -> %0d (steps %0d, want %0d)", pic_trk0, stable_pic, trk_cnt, pic_exp);
        end
        $display("STEP %-30s pic %0d -> %0d (track steps %0d)", "K4 prev track -> prev picture", pic_trk0, stable_pic, trk_cnt);
        // K2 停止(= MUSIC OFF)
        short_press(2);
        wait (dut.wav_selected == 1'b0);
        if (dut.m_music) begin errors++; $display("ERROR K2 stop did not clear MUSIC"); end
        in_wav = 0;
        sw[1] = 0;
        // 8. SPECTRUM 选项与 OUTPUT
        sw[0] = 1; menu_goto(4); short_press(4); short_press(4);
        if (dut.m_spec != 2) begin errors++; $display("ERROR spectrum %0d", dut.m_spec); end
        expect_row(9, 0, " SPECTRUM   < PLAY-RAW >", "spectrum play-raw");
        menu_goto(6); short_press(4);
        if (!dut.m_spk) begin errors++; $display("ERROR output spk"); end
        long_press(3);                                  // K3 长按 = 恢复默认
        if (dut.m_spec != 0 || dut.m_info || dut.m_spk || dut.period_s != 3 || dut.m_focus != 0) begin
            errors++; $display("ERROR defaults not restored");
        end
        sw[0] = 0; wait_frames(2);
        if (dut.u_osd.cram[0] != 8'd0) begin errors++; $display("ERROR marquee not cleared"); end
        // 9. 图墙与缩放(K4 短按缩放), PERIOD 关
        sw[0] = 1; menu_goto(3); repeat (3) short_press(3); sw[0] = 0;
        goto_pic(2);
        short_press(4); wait_label(22, 300, "K4 zoom /2 (PIC2)");
        short_press(4); wait_label(24, 300, "K4 zoom /4 (PIC2)");
        short_press(4); wait_label(2, 300, "K4 zoom back /1");
        long_press(2); wait_label(32, 600, "K2 long -> wall focus 2");
        short_press(2); wait_label(33, 300, "wall focus 3");
        long_press(2); wait_label(3, 600, "K2 long -> fullscreen PIC3");
        // 10. K3 长按重载
        long_press(3);
        wait_label(1, 600, "K3 long reload -> PIC1");
        wait_frames(3);

        // 11. KEY1 全局复位: 再次播放启动动画, 期间 K2 跳过; 进入首图后不得顺带翻到 PIC2
        sdram_err0 = dut.u_vmem.u_sdram.err_count;
        rst_n = 0; #(64'd2 * 1000000000); rst_n = 1;
        wait_label(60, 600, "after KEY1: boot frame 0");
        short_press(2);
        wait_label(1, 400, "K2 skip boot -> PIC1");
        wait (dut.u_mc.boot_pend == 1'b0);
        repeat (5) begin @(frame_done); if (cur_label != 1) begin errors++; $display("ERROR after skip label %0d", cur_label); end end
        if (dut.u_mc.nav_pend) begin errors++; $display("ERROR skip key leaked as page turn"); end
        $display("STEP %-30s label=%0d", "skip consumed, PIC1 stays", cur_label);

        if (dut.u_vmem.ref_overrun) begin errors++; $display("ERROR ref_overrun"); end
        if (dut.u_vmem.dma_late_cnt != 0) begin errors++; $display("ERROR dma_late %0d", dut.u_vmem.dma_late_cnt); end
        if (sdram_err0 != 0) begin errors++; $display("ERROR sdram model %0d before KEY1", sdram_err0); end
        if (dut.u_vmem.u_sdram.err_count > sdram_err0 + 1) begin
            errors++; $display("ERROR sdram model %0d after KEY1 (only the reset refresh gap is expected)", dut.u_vmem.u_sdram.err_count - sdram_err0);
        end
        if (vframes_seen < 16) begin errors++; $display("ERROR too few video frames %0d", vframes_seen); end
        if (aud_n < 4000) begin errors++; $display("ERROR too few video samples %0d", aud_n); end
        if (max_dev > 1602) begin errors++; $display("ERROR av deviation %0d", max_dev); end
        errors += vseq_err + vtear_err + aud_err + wav_err + (pause_nz != 0);
        $display("SUMMARY frames=%0d vframes=%0d vseq_err=%0d vtear=%0d vaud_n=%0d vaud_err=%0d av_dev_max=%0d wav_n=%0d wav_err=%0d wav_segs=%0d wav_skip=%0d wav_stall=%0d pause_nz=%0d",
                 frames, vframes_seen, vseq_err, vtear_err, aud_n, aud_err, max_dev, wav_n, wav_err, wav_seg, wav_skip, wav_stall, pause_nz);
        if (errors == 0) $display("RESULT PASS errors=0 @%0t ns", $time / 1000);
        else $display("RESULT FAIL errors=%0d @%0t ns", errors, $time / 1000);
        $finish;
    end
    initial begin #(64'd6000 * 1000000000); $display("RESULT FAIL global timeout"); $finish; end
endmodule
