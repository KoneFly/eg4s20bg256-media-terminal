`timescale 1ns/1ps
// 频谱叠加单元台: 真实 t073_spectrum_overlay + 快照表读口模型(读延迟 1, 与 multi_snapshot_table 同)。
// 原始桶值每 3 帧换一次(随机底 + 孤立单桶尖刺), 台内独立模型按规格计算:
//   频段 3 点平滑 + 上升 1/4 / 回落 1/8 的 6.3 定点状态; 首行显示更新前、其余行显示更新后;
//   音柱/插值波形掩码、横纵双向渐变色、波形 1:1 与音柱压波形 1:1 混合。
// 逐像素比较绘图区(387..450 行, x 64..575)与绘图区上方若干行(须等于原图像)。
module tb_spectrum_smooth;
    reg clk = 0; always #20 clk = ~clk;
    reg rst = 1;
    reg [9:0] hc = 0, vc = 0;
    reg       de = 0, fb_pulse = 0;
    reg [9:0] px = 0, py = 0;
    always @(posedge clk) begin
        if (hc == 799) begin hc <= 0; vc <= (vc == 524) ? 0 : vc + 1; end else hc <= hc + 1;
        de <= (hc >= 144 && hc < 784 && vc >= 35 && vc < 515);
        px <= hc - 10'd144; py <= vc - 10'd35;
        fb_pulse <= (hc == 0 && vc == 515);
    end
    wire [15:0] img = {px[4:0] ^ py[6:2], px[7:2], py[4:0]};

    // ---- 快照表读口模型 ----
    reg [5:0] raw [0:1][0:127];
    wire [8:0] ra, rb;
    reg  [7:0] rdq, rdbq;
    reg  [8:0] raq, rbq;
    reg        vq, vbq;
    localparam [1:0] PATHS = 2'd2;
    always @(posedge clk) begin
        rdq  <= {raw[ra[7]][ra[6:0]], 2'b00};  raq <= ra; vq  <= !fb_pulse && ({1'b0, ra} < {1'b0, PATHS, 7'd0});
        rdbq <= {raw[rb[7]][rb[6:0]], 2'b00}; rbq <= rb; vbq <= !fb_pulse && ({1'b0, rb} < {1'b0, PATHS, 7'd0});
    end
    wire [15:0] out;
    reg dual_req = 1, single_req = 0;
    t073_spectrum_overlay dut(.pixel_clk(clk), .pixel_rst(rst), .frame_boundary(fb_pulse), .de(de),
        .pixel_x(px), .absolute_line(py), .dual_requested(dual_req), .single_requested(single_req),
        .display_valid(1'b1), .display_bank(1'b0), .display_paths(PATHS),
        .read_address(ra), .read_data_q(rdq), .read_address_q(raq), .read_bank_q(1'b0), .read_valid_q(vq),
        .read_address_b(rb), .read_data_b_q(rdbq), .read_address_b_q(rbq), .read_bank_b_q(1'b0), .read_valid_b_q(vbq),
        .image_rgb565(img), .rgb565(out));

    // ---- 独立模型 ----
    int s_old [0:1][0:127];
    int s_new [0:1][0:127];
    function automatic int upd(input int s, input int rp, input int rc, input int rn);
        int t; t = (rp + 2 * rc + rn) * 2;          // 6.3 定点
        if (t > s) return s + ((t - s) >> 2);
        return s - ((s - t) >> 3);
    endfunction
    function automatic int fl4(input int v);         // 向下取整的 v/4
        return (v >= 0) ? (v / 4) : -((-v + 3) / 4);
    endfunction
    function automatic [15:0] avg565(input [15:0] a, input [15:0] b);
        avg565 = {1'b0, a[15:12], 1'b0, a[10:6], 1'b0, a[4:1]} + {1'b0, b[15:12], 1'b0, b[10:6], 1'b0, b[4:1]};
    endfunction
    task automatic new_frame_model();
        for (int p = 0; p < 2; p++) for (int i = 0; i < 128; i++) begin
            int rp, rn;
            s_old[p][i] = s_new[p][i];
        end
        for (int p = 0; p < 2; p++) for (int i = 0; i < 128; i++) begin
            int rp, rn;
            rp = raw[p][(i == 0) ? 0 : i - 1]; rn = raw[p][(i == 127) ? 127 : i + 1];
            s_new[p][i] = upd(s_old[p][i], rp, raw[p][i], rn);
        end
    endtask
    function automatic [15:0] expect_px(input int x, input int y, input bit both, input [15:0] im);
        int bin, ph, bd, hb, hc2, hn, hi, fbv, g;
        bit bm, wm; bit [15:0] bar, wav;
        bin = (x - 64) >> 2; ph = (x - 64) & 3; bd = 450 - y;
        hb  = ((y == 387) ? s_old[0][bin] : s_new[0][bin]) >> 3;
        hc2 = ((y == 387) ? s_old[1][bin] : s_new[1][bin]) >> 3;
        hn  = ((y == 387) ? s_old[1][(bin == 127) ? 127 : bin + 1] : s_new[1][(bin == 127) ? 127 : bin + 1]) >> 3;
        hi  = hc2 + fl4((hn - hc2) * ph);
        bm  = (ph != 3) && (bd <= hb) && (hb != 0);
        wm  = both && (bd <= hi) && (hi != 0);
        fbv = (x - 64) >> 4; g = (31 - fbv) + (31 - (bd >> 1));
        bar = {5'd31, g[5:0], 5'(fbv >> 1)};
        wav = {5'(fbv >> 1), g[5:0], 5'd31};
        if (bm) return wm ? avg565(bar, avg565(im, wav)) : bar;
        if (wm) return avg565(im, wav);
        return im;
    endfunction

    // ---- 原始数据: 每 3 帧换一组, 带孤立尖刺 ----
    int frame = 0, errors = 0, checked = 0, spike_max = 0, n_bar = 0, n_wave = 0, n_both = 0;
    task automatic new_raw();
        for (int p = 0; p < 2; p++) for (int i = 0; i < 128; i++)
            raw[p][i] = 6'($urandom_range(0, 30) + ((i % 40) < 20 ? 10 : 0));
        if ((frame / 3) % 2 == 0) begin raw[0][50] = 63; raw[0][49] = 0; raw[0][51] = 0; end
    endtask

    always @(posedge clk) begin
        if (fb_pulse) begin
            frame <= frame + 1;
        end
    end
    initial begin
        for (int p = 0; p < 2; p++) for (int i = 0; i < 128; i++) begin s_new[p][i] = 0; raw[p][i] = 0; end
        // 复位在消隐期释放
        wait (vc == 518); @(negedge clk); rst = 0;
    end
    // 帧边界(消隐期): 换数据并推进模型(DUT 在下一帧首行更新)
    always @(posedge clk) if (!rst && fb_pulse) begin
        if (frame % 3 == 0) new_raw();
        new_frame_model();
        if (frame == 40) single_req <= 1;          // 切到 PLAY(只音柱)
        if (frame == 40) dual_req <= 0;
    end
    // 逐像素核对(第 3 帧起, 模式切换后两帧不查)
    always @(negedge clk) if (!rst && de && frame >= 3 && !(frame >= 40 && frame <= 41)) begin
        if (py >= 300 && py <= 450) begin
            bit both; reg [15:0] e;
            both = (frame < 40);
            if (py < 387 || px < 64 || px >= 576) e = img;
            else begin
                e = expect_px(px, py, both, img);
                if (dut.bar_mask && dut.wave_mask) n_both++; else if (dut.bar_mask) n_bar++; else if (dut.wave_mask) n_wave++;
            end
            if (out !== e) begin
                if (errors < 8) $display("ERROR f=%0d x=%0d y=%0d got %h exp %h", frame, px, py, out, e);
                errors++;
            end
            checked++;
        end
    end
    // 第 30 帧(PLAY-RAW)与第 50 帧(PLAY)整帧转储, 供目视
    integer fd30 = 0;
    always @(negedge clk) if (!rst && de) begin
        if ((frame == 30 || frame == 50) && px == 0 && py == 0) begin
            if (fd30 != 0) $fclose(fd30);
            fd30 = $fopen(frame == 30 ? "sim/spec_playraw.hex" : "sim/spec_play.hex", "w");
        end
        if ((frame == 30 || frame == 50) && fd30 != 0) $fwrite(fd30, "%h\n", out);
    end
    // 尖刺桶的显示高度(平滑后)
    always @(posedge clk) if (!rst && fb_pulse && frame > 3) begin
        if ((s_new[0][50] >> 3) > spike_max) spike_max = s_new[0][50] >> 3;
    end
    initial begin
        wait (frame == 60);
        $display("SUMMARY frames=%0d pixels_checked=%0d errors=%0d bar_only=%0d wave_only=%0d bar_over_wave=%0d spike_raw=63 spike_shown_max=%0d",
                 frame, checked, errors, n_bar, n_wave, n_both, spike_max);
        if (errors == 0 && checked > 1000000 && n_bar > 10000 && n_wave > 10000 && n_both > 10000) $display("RESULT PASS"); else $display("RESULT FAIL");
        $finish;
    end
endmodule
