`timescale 1ns / 1ps
// bmp_page_loader 台: 读 sim/bmp_in.hex 字流(随机间隔喂入), 收集行输出组成 640×480 帧,
// 与 make_bmp_case.py 的独立期望逐像素比对; 下游随机背压。
module tb_bmp_loader;
    reg clk = 0; always #10 clk = ~clk;
    reg rst_n = 0;

    reg         start = 0, in_valid = 0;
    reg  [31:0] in_data = 0;
    wire        in_ready, row_valid, row_last, done, err;
    wire [31:0] row_data;
    wire [8:0]  row_y;
    reg         row_ready = 1;
    wire [15:0] img_w, img_h;

    bmp_page_loader dut (.clk(clk), .rst_n(rst_n), .start(start), .in_valid(in_valid), .in_data(in_data),
        .in_ready(in_ready), .row_valid(row_valid), .row_data(row_data), .row_y(row_y), .row_last(row_last),
        .row_ready(row_ready), .done(done), .err(err), .img_w(img_w), .img_h(img_h));

    reg [31:0] words [0:4194303];
    reg [15:0] expv  [0:307199];
    reg [15:0] got   [0:307199];
    reg     started = 0;
    integer nwords, i, wi = 0, nrows = 0, ncol = 0, bp = 0, perr = 0, rowdup = 0;
    reg     row_seen [0:479];

    // 输入: 字流按序送出, valid 期间数据保持
    always @(posedge clk) begin
        if (in_valid && in_ready) begin
            wi = wi + 1;
            in_valid <= 1'b0;
        end
        if ((!in_valid || in_ready) && wi < nwords && $urandom_range(0, 3) != 0 && started) begin
            in_valid <= 1'b1;
            in_data  <= words[(in_valid && in_ready) ? wi : wi];
        end
    end

    // 输出收集
    always @(posedge clk) begin
        row_ready <= (bp == 0) ? 1'b1 : ($urandom_range(0, 99) >= bp);
        if (row_valid && row_ready) begin
            got[row_y * 640 + ncol * 2]     = row_data[15:0];
            got[row_y * 640 + ncol * 2 + 1] = row_data[31:16];
            if (row_last) begin
                if (ncol != 319) begin $display("ERR row %0d short (%0d)", row_y, ncol); perr++; end
                if (row_seen[row_y]) rowdup++;
                row_seen[row_y] = 1;
                ncol = 0; nrows++;
            end else ncol++;
        end
    end

    initial begin
        if (!$value$plusargs("n=%d", nwords)) nwords = 0;
        if ($value$plusargs("bp=%d", bp)) ;
        $readmemh("sim/bmp_in.hex", words, 0, nwords - 1);
        $readmemh("sim/bmp_expect.hex", expv);
        for (i = 0; i < 480; i++) row_seen[i] = 0;
        repeat (5) @(negedge clk); rst_n = 1;
        repeat (5) @(negedge clk); start = 1; @(negedge clk); start = 0; started = 1;
        fork
            begin @(posedge done); end
            begin #2_000_000_000; $display("RESULT FAIL timeout wi=%0d/%0d rows=%0d", wi, nwords, nrows); $finish; end
        join_any
        repeat (20) @(negedge clk);
        for (i = 0; i < 307200; i++) if (got[i] !== expv[i]) begin
            if (perr < 8) $display("PIXERR y=%0d x=%0d got=%h exp=%h", i / 640, i % 640, got[i], expv[i]);
            perr++;
        end
        begin : br
            int r, c, z; $write("BLACKROWS");
            for (r = 0; r < 480; r++) begin z = 1; for (c = 0; c < 640; c++) if (got[r*640+c] !== 0) z = 0; if (z) $write(" %0d", r); end
            $display("");
        end
        $display("SUMMARY img=%0dx%0d err=%0d rows=%0d dup=%0d words=%0d/%0d pix_err=%0d", img_w, img_h, err,
                 nrows, rowdup, wi, nwords, perr);
        if (!err && nrows == 480 && rowdup == 0 && perr == 0) $display("RESULT PASS"); else $display("RESULT FAIL");
        $finish;
    end
endmodule
