`timescale 1ns/1ps
// 淡入淡出混合两种实现逐位对照: 移位加版(rtl) 与 DSP 乘法版(rtl_f2b, 模块改名 te_mul)。
// 穷举 G 通道 64×64 对、R/B 通道随 G 下标折叠覆盖 32×32 对, 进度 t 取 0..255 全部值。
module tb_fade_equiv;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;
    reg [15:0] a = 0, b = 0;
    reg [7:0] t = 0;
    wire de0, de1;
    wire [15:0] p0, p1;
    transition_engine_curtain u_ref (.clk(clk), .rst_n(rst_n), .a_de(1'b1), .a_pixel(a), .b_de(1'b1), .b_pixel(b),
        .trans_mode(3'd1), .trans_t(t), .px_x(12'd0), .px_y(12'd0), .out_de(de0), .out_pixel(p0));
    te_mul u_new (.clk(clk), .rst_n(rst_n), .a_de(1'b1), .a_pixel(a), .b_de(1'b1), .b_pixel(b),
        .trans_mode(3'd1), .trans_t(t), .px_x(12'd0), .px_y(12'd0), .out_de(de1), .out_pixel(p1));
    integer ga, gb, tt, n = 0, bad = 0;
    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        for (tt = 0; tt < 256; tt = tt + 1)
            for (ga = 0; ga < 64; ga = ga + 1)
                for (gb = 0; gb < 64; gb = gb + 1) begin
                    @(negedge clk);
                    t = tt;
                    a = {ga[4:0], ga[5:0], gb[4:0]};
                    b = {gb[4:0], gb[5:0], ga[4:0] ^ 5'h15};
                    @(posedge clk); #1;
                    if (de0 !== de1 || p0 !== p1) begin
                        if (bad < 5) $display("MISMATCH t=%0d a=%h b=%h ref=%h new=%h", tt, a, b, p0, p1);
                        bad = bad + 1;
                    end
                    n = n + 1;
                end
        $display("SUMMARY vectors=%0d mismatches=%0d", n, bad);
        if (bad == 0) $display("RESULT PASS"); else $display("RESULT FAIL");
        $finish;
    end
endmodule
