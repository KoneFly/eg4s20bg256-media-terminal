`timescale 1ns/1ps
// WAV 解析器对照台: 同一组用例(tools/gen_wav_cases)分别驱动参考实现 ref_wav_parser(上一版已验收
// RTL 改名)与精简实现 t072_wav_parser, 各自独立的输入节拍与随机 pcm_ready 背压。
// 逐例比较: 样本序列(个数 + 逐个值)、结局(eof/error)、错误码、header_valid、samples_total。
module tb_wav_equiv;
    reg clk = 0; always #10 clk = ~clk;
    reg rst_n = 0;
    reg start = 0, done_p = 0;
    reg [31:0] fsize = 0;
    reg [31:0] words [0:65535];
    integer nwords = 0;

    // ---- 两个实例 ----
    reg        va = 0, vb = 0;
    reg [31:0] da = 0, db = 0;
    wire       ra, rb, pva, pvb, hva, hvb, eofa, eofb, erra, errb;
    wire [15:0] pa, pb;
    wire [3:0] ca, cb;
    wire [31:0] ta, tb;
    reg        pra = 1, prb = 1;
    ref_wav_parser u_ref (.clk(clk), .rst_n(rst_n), .start(start), .file_size(fsize),
        .in_valid(va), .in_data(da), .in_ready(ra), .stream_done(done_p),
        .pcm_valid(pva), .pcm(pa), .pcm_ready(pra), .header_valid(hva), .eof(eofa), .error(erra),
        .error_code(ca), .samples_total(ta), .busy());
    t072_wav_parser u_new (.clk(clk), .rst_n(rst_n), .start(start), .file_size(fsize),
        .in_valid(vb), .in_data(db), .in_ready(rb), .stream_done(done_p),
        .pcm_valid(pvb), .pcm(pb), .pcm_ready(prb), .header_valid(hvb), .eof(eofb), .error(errb),
        .error_code(cb), .samples_total(tb), .busy());

    // ---- 样本收集 ----
    reg [15:0] sa [0:4095];
    reg [15:0] sb [0:4095];
    integer na = 0, nb = 0;
    reg [31:0] lf = 32'h1234_5678;
    always @(posedge clk) begin
        lf <= {lf[30:0], lf[31] ^ lf[21] ^ lf[1] ^ lf[0]};
        pra <= lf[3] | lf[7];
        prb <= lf[11] | lf[5];
        if (pva && pra) begin if (na < 4096) sa[na] = pa; na = na + 1; end
        if (pvb && prb) begin if (nb < 4096) sb[nb] = pb; nb = nb + 1; end
    end

    // ---- 独立送字(随机间隙) ----
    reg feed_go = 0;
    integer fa_done = 0, fb_done = 0;
    task automatic feeder(input bit which);
        integer i;
        for (i = 0; i < nwords; i++) begin
            @(negedge clk);
            if (which == 0) begin va = 1; da = words[i]; end else begin vb = 1; db = words[i]; end
            @(posedge clk);
            while (which == 0 ? !ra : !rb) @(posedge clk);
            @(negedge clk);
            if (which == 0) va = 0; else vb = 0;
            if ((i + which) % 5 == 3) @(negedge clk);
        end
        if (which == 0) fa_done = 1; else fb_done = 1;
    endtask

    integer fd, ncase = 0, nbad = 0, k, cyc, n_eof = 0, n_samp = 0;
    integer hist [0:15];
    initial for (int q = 0; q < 16; q++) hist[q] = 0;
    string tagc;
    integer fs, nw;
    initial begin
        fd = $fopen("sim/wav_cases.txt", "r");
        if (fd == 0) begin $display("RESULT FAIL no cases"); $finish; end
        repeat (3) @(negedge clk); rst_n = 1;
        forever begin
            void'($fscanf(fd, "%s %d %d", tagc, fs, nw));
            if (tagc != "C") break;
            for (k = 0; k < nw; k++) void'($fscanf(fd, "%h", words[k]));
            nwords = nw; fsize = fs; na = 0; nb = 0; fa_done = 0; fb_done = 0;
            @(negedge clk); start = 1; @(negedge clk); start = 0;
            fork feeder(0); feeder(1); join_none
            cyc = 0;
            while (!(fa_done && fb_done) && cyc < 200000) begin @(posedge clk); cyc++; end
            @(negedge clk); done_p = 1; @(negedge clk); done_p = 0;
            cyc = 0;
            while (!((eofa || erra) && (eofb || errb)) && cyc < 2000) begin @(posedge clk); cyc++; end
            repeat (40) @(posedge clk);
            begin
                bit bad; bad = 0;
                if (eofa != eofb || erra != errb || ca != cb || hva != hvb || ta != tb || na != nb) bad = 1;
                for (k = 0; k < na && k < 4096; k++) if (sa[k] !== sb[k]) bad = 1;
                if (bad) begin
                    nbad++;
                    if (nbad <= 10) $display("MISMATCH case %0d fsize=%0d: ref eof=%0d err=%0d code=%0d hv=%0d tot=%0d n=%0d | new eof=%0d err=%0d code=%0d hv=%0d tot=%0d n=%0d",
                        ncase, fs, eofa, erra, ca, hva, ta, na, eofb, errb, cb, hvb, tb, nb);
                end
            end
            if (eofa) n_eof++; else hist[ca]++;
            n_samp += na;
            ncase++;
        end
        $display("COVER eof=%0d samples=%0d err1=%0d err2=%0d err3=%0d err4=%0d err5=%0d err6=%0d",
                 n_eof, n_samp, hist[1], hist[2], hist[3], hist[4], hist[5], hist[6]);
        $display("SUMMARY cases=%0d mismatches=%0d", ncase, nbad);
        if (nbad == 0 && ncase > 100) $display("RESULT PASS");
        else $display("RESULT FAIL");
        $finish;
    end
endmodule
