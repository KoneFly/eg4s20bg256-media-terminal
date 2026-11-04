`timescale 1ns / 1ps
// FAT32 扫描台: 卡模型加载 make_fat_image.py 生成的镜像, 期望 extent 来自同一脚本
// 的独立计算(sim/fat_expect.txt)。另测一个不存在的文件名应报 E_NF(3)。
module tb_fat32_scan;
    reg clk = 0; always #10 clk = ~clk;
    reg rst_n = 0;

    wire       sd_clk, sd_cmd;
    wire [3:0] sd_dat;
    pullup (sd_cmd);
    pullup (sd_dat[0]); pullup (sd_dat[1]); pullup (sd_dat[2]); pullup (sd_dat[3]);
    sd_card_model #(.ACMD41_BUSY(1), .NAC_MAX(20)) card (.sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_dat(sd_dat));

    wire        init_done, init_err, hs_mode, st_busy, st_done, st_err;
    wire [3:0]  init_stage, pool_count;
    wire [31:0] card_blocks, pool_rdata;
    wire [15:0] st_blocks, st_count;
    wire        st_start, pool_release;
    wire [31:0] st_lba;
    wire [6:0]  pool_raddr;

    sd_host #(.ACMD41_TRIES(100)) u_sd (
        .clk(clk), .rst_n(rst_n), .cfg(3'b000), .reinit(1'b0),
        .init_done(init_done), .init_err(init_err), .init_stage(init_stage), .hs_mode(hs_mode),
        .card_blocks(card_blocks),
        .st_start(st_start), .st_lba(st_lba), .st_count(st_count), .st_busy(st_busy),
        .st_done(st_done), .st_err(st_err), .st_blocks(st_blocks),
        .pool_count(pool_count), .pool_raddr(pool_raddr), .pool_rdata(pool_rdata),
        .pool_release(pool_release),
        .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_dat(sd_dat));

    reg         start = 0;
    reg  [87:0] name83;
    wire        busy, done;
    wire [2:0]  err_code;
    wire [31:0] file_size, ext_lba, ext_blocks;
    wire [7:0]  n_ext;
    reg  [6:0]  ext_raddr = 0;

    fat32_scan u_fat (
        .clk(clk), .rst_n(rst_n), .start(start), .name83(name83), .bank(1'b1),
        .busy(busy), .done(done), .err_code(err_code), .file_size(file_size), .n_ext(n_ext),
        .ext_raddr({1'b1, ext_raddr}), .ext_lba(ext_lba), .ext_blocks(ext_blocks),
        .init_done(init_done), .st_start(st_start), .st_lba(st_lba), .st_count(st_count),
        .st_done(st_done), .st_err(st_err), .pool_count(pool_count), .pool_raddr(pool_raddr),
        .pool_rdata(pool_rdata), .pool_release(pool_release));

    task automatic scan(input [87:0] nm);
        @(negedge clk); name83 = nm; start = 1;
        @(negedge clk); start = 0;
        @(posedge done); @(negedge clk);
    endtask

    integer fd, r, exp_size, exp_n, i, el, eb, bad = 0;
    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1;
        wait (init_done || init_err);
        if (!init_done) begin $display("RESULT FAIL init"); $finish; end

        scan("VID00000V29");
        fd = $fopen("sim/fat_expect.txt", "r");
        r = $fscanf(fd, "%d %d\n", exp_size, exp_n);
        $display("SUMMARY err=%0d size=%0d(exp %0d) n_ext=%0d(exp %0d)", err_code, file_size, exp_size, n_ext, exp_n);
        if (err_code != 0 || file_size != exp_size || n_ext != exp_n) bad++;
        for (i = 0; i < exp_n; i++) begin
            r = $fscanf(fd, "%d %d\n", el, eb);
            ext_raddr = i; @(negedge clk); @(negedge clk);
            $display("SUMMARY ext%0d lba=%0d blocks=%0d (exp %0d %0d)", i, ext_lba, ext_blocks, el, eb);
            if (ext_lba != el || ext_blocks != eb) bad++;
        end
        $fclose(fd);

        scan("NOFILE  V29");
        $display("SUMMARY missing err=%0d (exp 3)", err_code);
        if (err_code != 3) bad++;

        scan("PIC1    BMP");
        $display("SUMMARY pic1 err=%0d size=%0d n_ext=%0d (exp 0 1000 1)", err_code, file_size, n_ext);
        if (err_code != 0 || file_size != 1000 || n_ext != 1) bad++;

        $display("SUMMARY card_err=%0d", card.errors);
        if (bad == 0 && card.errors == 0) $display("RESULT PASS"); else $display("RESULT FAIL");
        $finish;
    end
    initial begin #2_000_000_000; $display("RESULT FAIL timeout"); $finish; end
endmodule
