// ---------------------------------------------------------------------------
// fat32_lite — FAT32 只读层(米醋栈适配层)
//
// 角色与边界:
//   本模块是第七讲完赛工程 FAT32 栈(sd_spi_sector_reader /
//   sd_sector_replay_buffer / fat32_volume_scanner / fat32_file_streamer)
//   对 task_022 冻结接口(009 线接口)的适配层。对外端口 = 冻结接口逐端口
//   保留 + 新增 2 个输入(init_ready / card_high_capacity), 因此 m1a_top、
//   加载 FSM、bmp_sdram_loader 与契约 TB 对内部实现不感知。
//
//   内部结构(照抄米醋 media_ingest_frontend / media_ingest_pipeline 接线):
//
//     sd_spi_sector_reader u_reader  ← init_ready(锁存) / card_high_capacity
//                                   SPI 三线直出(编译期 CLK_DIV 分频)
//             ↕ reader_req/lba ↔ reader_busy/valid/byte/byte_index/done/error
//     sd_sector_replay_buffer u_replay(512B 捕获-重放)
//             ↕ sector_req/lba ↔ sector_busy/valid/byte/byte_index/done/error
//     fat32_volume_scanner u_scanner  ─┐
//                                      ├─ 扇区仲裁:
//     fat32_file_streamer  u_streamer ─┘  sector_req = scan | file;
//                                         sector_lba = scan ? scan : file
//
// 语义映射(冻结接口 → 米醋栈):
//   * 资源槽固定 4 个: PIC1.BMP..PIC4.BMP(scanner 按固定名匹配, 目录项须
//     落在根目录起始扇区前 16 项内; 缺一即 ERR_RESOURCE_MISSING →
//     mount_error)。file_count = 4 槽 resource_valid 的 popcount;
//   * query_index N → 固定合成名 "PICn    BMP"(8.3 目录项 11 字节, 88bit),
//     query_size ← 槽 size, query_is_bmp ← 槽 resource_valid,
//     query_is_wav 恒 0; query_* 为 1 拍延迟寄存输出;
//   * read_start+read_index → streamer.file_start(槽 first_cluster/size +
//     scanner 几何参数); mount/read 时序互斥;
//   * data_out/data_valid ← streamer 字节流按大端序 4 字节打包, 每 4 字节
//     data_valid 单拍; 文件尾不足 4 字节时右对齐补 0(与 loader 输入契约
//     一致), 流字数 = ceil(size/4);
//   * read_error/mount_error ← streamer/scanner 的 fs_error != 0。
//
// 接口适配细节:
//   * init_ready: 003 的 init_done 为单拍脉冲, 本层锁存为电平供 reader
//     检查; card_high_capacity 为 003 电平输出, 直通;
//   * SPI 时钟: reader 的 SPI_CLK_DIV 为编译期参数(米醋字节引擎按
//     2×CLK_DIV 分频)。[2026-09-21 提速] 真值 7→2: SCK 3.57→12.5MHz
//     (SD SPI 规范默认档 25MHz 的一半; 640×480 切换纯传输 2.06s→0.59s)。
//     顶层 spi_clk_div 端口为冻结接口未接入(026 顶层传 16'd2 未生效,
//     分频始终由本层 SPI_CLK_DIV_SIM 常量决定), 端口按冻结接口保留;
//   * sd_spi_command.v 同栈采用但本层未实例化(reader 内嵌 CMD17 装配)。
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module fat32_lite #(
    parameter BYTE_DIV_WIDTH = 16,
    parameter MAX_FILES      = 16          // 冻结接口参数保留(本层固定 4 槽)
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // 003 初始化结果: init_ready=init_done(脉冲, 本层锁存), 卡容量类型
    input  wire                      init_ready,
    input  wire                      card_high_capacity,

    input  wire                      mount_start,
    output reg                       mount_busy,
    output reg                       mount_done,
    output reg                       mount_error,
    output wire [4:0]                file_count,

    input  wire [4:0]                query_index,
    output wire [87:0]               query_name,
    output wire [31:0]               query_size,
    output wire                      query_is_bmp,
    output wire                      query_is_wav,

    input  wire                      read_start,
    input  wire [4:0]                read_index,
    output reg                       read_busy,
    output reg                       read_done,
    output reg                       read_error,

    output reg  [31:0]               data_out,
    output reg                       data_valid,

    // [task_032 音频集成] WAV 槽引出(扫描器直通, 纯新增端口):
    //   WAV1.WAV~WAV4.WAV 的 first_cluster/size 供顶层做簇→LBA 换算后
    //   驱动 wav_pcm_streamer。挂载成功条件仍只看 PIC 槽(resource_valid),
    //   WAV 槽缺失不影响 mount。
    output wire [3:0]                wav_valid,
    output wire [31:0]               wav0_first_cluster,
    output wire [31:0]               wav1_first_cluster,
    output wire [31:0]               wav2_first_cluster,
    output wire [31:0]               wav3_first_cluster,
    output wire [31:0]               wav0_size,
    output wire [31:0]               wav1_size,
    output wire [31:0]               wav2_size,
    output wire [31:0]               wav3_size,
    // [task_032] 几何参数引出(挂载完成后稳定; 顶层缓存用于簇→LBA 换算)
    output wire [31:0] selected_pic_cluster,selected_pic_size,
    output wire [3:0] cached_pic_valid,
    output wire lrc_entry_valid,
    output wire [1:0] lrc_entry_slot,
    output wire [31:0] lrc_entry_cluster,lrc_entry_size,lrc_fat_start,lrc_max_cluster,
    output wire [31:0]               data_start_lba_out,
    output wire [7:0]                sectors_per_cluster_out,

    // [task_032 音频集成] 文件流器扇区读端口外引:
    //   file_streamer 的扇区事务经顶层 sd_arbiter 与 WAV 源统一仲裁后, 由
    //   本层新增的 arb_* 输入口回灌到 replay 缓冲。扫描器仍在层内直连
    //   (挂载期与 read 期时序互斥, 无并发)。
    output wire                      file_sector_req,
    output wire [31:0]               file_sector_lba,
    input  wire                      file_sector_busy,
    input  wire                      file_sector_valid,
    input  wire [7:0]                file_sector_byte,
    input  wire [8:0]                file_sector_byte_index,
    input  wire                      file_sector_done,
    input  wire [7:0]                file_sector_error,

    // [task_032] 仲裁后回灌口: 顶层 sd_arbiter 输出 → 本层 replay 缓冲。
    //   与扫描器的内部请求同构, 由本层做二选一(挂载期扫描器独占,
    //   读取期 arb 回灌独占, 二者时序互斥)。
    input  wire                      arb_sector_req,
    input  wire [31:0]               arb_sector_lba,
    output wire                      arb_sector_busy,
    output wire                      arb_sector_valid,
    output wire [7:0]                arb_sector_byte,
    output wire [8:0]                arb_sector_byte_index,
    output wire                      arb_sector_done,
    output wire [7:0]                arb_sector_error,

    output wire                      spi_cs_n,
    output wire                      spi_sck,
    output wire                      spi_mosi,
    input  wire                      spi_miso,
    input  wire [BYTE_DIV_WIDTH-1:0] spi_clk_div
);

    localparam [4:0] FILE_SLOTS = 5'd4;

    // SPI 分频: [task_046 B1 提速] 真值 2→1, SCK = 50M/(2×1) = 25MHz
    //   (SD SPI 规范上限)。前置 = mx_byte_engine 位时序修正(下降沿当拍备妥
    //   下一位 MOSI, 消灭 div==1 的同沿风险; 单元台两档逐位验证通过后
    //   方可置本常量, doc/output/B1_SPI_TIMING.md); 假卡模型按 SCK 沿逐位
    //   服务, 行为覆盖两档。回退 = 本常量改回 2(12.5MHz, B0 基线档)。
    `ifdef TB_FAST_SD
        localparam integer SPI_CLK_DIV_SIM = 1;
    `else
        localparam integer SPI_CLK_DIV_SIM = 1;
    `endif

    // ------------------------------------------------------------------
    // init_ready 锁存: 003 init_done 为单拍脉冲, reader 需要电平
    // ------------------------------------------------------------------
    reg init_ready_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          init_ready_r <= 1'b0;
        else if (init_ready) init_ready_r <= 1'b1;
    end

    // 胶水 FSM 启动脉冲(先声明后引用, 避免隐式 wire)
    reg scan_start, file_start;

    // ------------------------------------------------------------------
    // CMD17 扇区读器(SPI 直出, 含 mx_byte_engine)
    // ------------------------------------------------------------------
    wire        reader_busy, reader_valid, reader_done;
    wire [7:0]  reader_byte, reader_error;
    wire [8:0]  reader_byte_index;
    wire        reader_req;
    wire [31:0] reader_lba;

    sd_spi_sector_reader #(
        .SPI_CLK_DIV     (SPI_CLK_DIV_SIM),   // 真值 2(SCK=12.5MHz, 见上)
        .MAX_R1_BYTES    (16),
        // [2026-09-21 提速] 4096→16384: SCK 提速 3.5× 后 token 等待的墙钟
        // 预算不缩水(div=7: 4096B≈9.2ms; div=2: 16384B≈10.5ms), 真卡 Nac
        // 慢于 2.6ms 的情形不会从"慢但可用"劣化为 ERR_TOKEN_TIMEOUT(码 3)。
        .MAX_TOKEN_BYTES (16384),
        .CHECK_DATA_CRC  (1'b1)
    ) u_reader (
        .clk               (clk),
        .rst_n             (rst_n),
        .init_ready        (init_ready_r),
        .card_high_capacity(card_high_capacity),
        .sector_req        (reader_req),
        .sector_lba        (reader_lba),
        .sector_busy       (reader_busy),
        .sector_done       (reader_done),
        .sector_valid      (reader_valid),
        .sector_byte       (reader_byte),
        .sector_byte_index (reader_byte_index),
        .sector_error      (reader_error),
        .last_r1           (),
        .sd_cs_n           (spi_cs_n),
        .sd_sclk           (spi_sck),
        .sd_mosi           (spi_mosi),
        .sd_miso           (spi_miso)
    );

    // ------------------------------------------------------------------
    // 扇区捕获-重放缓冲(512B)
    // ------------------------------------------------------------------
    wire        replay_busy, replay_valid, replay_done;
    wire [7:0]  replay_byte, replay_error;
    wire [8:0]  replay_byte_index;
    wire        replay_req;
    wire [31:0] replay_lba;

    sd_sector_replay_buffer u_replay (
        .clk              (clk),
        .rst_n            (rst_n),
        .cache_invalidate (mount_start),
        .sector_req       (replay_req),
        .sector_lba       (replay_lba),
        .sector_busy      (replay_busy),
        .sector_valid     (replay_valid),
        .sector_byte      (replay_byte),
        .sector_byte_index(replay_byte_index),
        .sector_done      (replay_done),
        .sector_error     (replay_error),
        .reader_req       (reader_req),
        .reader_lba       (reader_lba),
        .reader_busy      (reader_busy),
        .reader_valid     (reader_valid),
        .reader_byte      (reader_byte),
        .reader_byte_index(reader_byte_index),
        .reader_done      (reader_done),
        .reader_error     (reader_error)
    );

    // ------------------------------------------------------------------
    // 卷扫描器(固定名 4 槽)与文件流器
    // ------------------------------------------------------------------
    wire        scan_busy, scan_done;
    wire [7:0]  scan_fs_error;
    wire [7:0]  scan_spc;
    wire [31:0] scan_fat_start, scan_data_start, scan_max_cluster;
    wire [3:0]  scan_resource_valid;
    wire [31:0] res0_cluster, res1_cluster, res2_cluster, res3_cluster;
    wire [31:0] res0_size, res1_size, res2_size, res3_size;
    wire        scan_sector_req;
    wire [31:0] scan_sector_lba;

    fat32_volume_scanner u_scanner (
        .clk                (clk),
        .rst_n              (rst_n),
        .scan_start         (scan_start),
        .scan_busy          (scan_busy),
        .scan_done          (scan_done),
        .fs_error           (scan_fs_error),
        .partition_lba      (),
        .sectors_per_cluster(scan_spc),
        .fat_start_lba      (scan_fat_start),
        .data_start_lba     (scan_data_start),
        .max_cluster        (scan_max_cluster),
        .resource_valid     (scan_resource_valid),
        .resource0_cluster  (res0_cluster),
        .resource1_cluster  (res1_cluster),
        .resource2_cluster  (res2_cluster),
        .resource3_cluster  (res3_cluster),
        .resource0_size     (res0_size),
        .resource1_size     (res1_size),
        .resource2_size     (res2_size),
        .resource3_size     (res3_size),
        // [task_032] WAV 槽引出
        .lrc_entry_valid(lrc_entry_valid),.lrc_entry_slot(lrc_entry_slot),
        .lrc_entry_cluster(lrc_entry_cluster),.lrc_entry_size(lrc_entry_size),
        .wav_valid          (wav_valid),
        .wav0_first_cluster (wav0_first_cluster),
        .wav1_first_cluster (wav1_first_cluster),
        .wav2_first_cluster (wav2_first_cluster),
        .wav3_first_cluster (wav3_first_cluster),
        .wav0_size          (wav0_size),
        .wav1_size          (wav1_size),
        .wav2_size          (wav2_size),
        .wav3_size          (wav3_size),
        .sector_req         (scan_sector_req),
        .sector_lba         (scan_sector_lba),
        .sector_busy        (replay_busy),
        .sector_valid       (replay_valid),
        .sector_byte        (replay_byte),
        .sector_byte_index  (replay_byte_index),
        .sector_done        (replay_done),
        .sector_error       (replay_error)
    );

    // [task_032] 几何参数引出(挂载完成后稳定; 顶层缓存用于簇→LBA)
    assign lrc_fat_start=scan_fat_start;
    assign lrc_max_cluster=scan_max_cluster;
    assign data_start_lba_out        = scan_data_start;
    assign sectors_per_cluster_out   = scan_spc;

    wire        file_busy, file_done, file_valid;
    wire [7:0]  file_byte, file_fs_error;
    wire [31:0] file_byte_offset;

    // 槽参数选择(read_index 在读期间由顶层 hit_idx_r 保持稳定)
    wire [31:0] slot_cluster = (read_index[1:0] == 2'd0) ? res0_cluster :
                               (read_index[1:0] == 2'd1) ? res1_cluster :
                               (read_index[1:0] == 2'd2) ? res2_cluster :
                                                           res3_cluster;
    wire [31:0] slot_size    = (read_index[1:0] == 2'd0) ? res0_size :
                               (read_index[1:0] == 2'd1) ? res1_size :
                               (read_index[1:0] == 2'd2) ? res2_size :
                                                           res3_size;

    assign cached_pic_valid=scan_resource_valid;
    assign selected_pic_cluster=slot_cluster;
    assign selected_pic_size=slot_size;
    fat32_file_streamer u_streamer (
        .clk                (clk),
        .rst_n              (rst_n),
        .file_start         (file_start),
        .first_cluster      (slot_cluster),
        .file_size          (slot_size),
        .sectors_per_cluster(scan_spc),
        .fat_start_lba      (scan_fat_start),
        .data_start_lba     (scan_data_start),
        .max_cluster        (scan_max_cluster),
        .file_busy          (file_busy),
        .file_done          (file_done),
        .file_valid         (file_valid),
        .file_byte          (file_byte),
        .file_byte_offset   (file_byte_offset),
        .fs_error           (file_fs_error),
        // [task_032] 扇区读端口外引: 由顶层 sd_arbiter 与 WAV 源统一仲裁
        .sector_req         (file_sector_req),
        .sector_lba         (file_sector_lba),
        .sector_busy        (file_sector_busy),
        .sector_valid       (file_sector_valid),
        .sector_byte        (file_sector_byte),
        .sector_byte_index  (file_sector_byte_index),
        .sector_done        (file_sector_done),
        .sector_error       (file_sector_error)
    );

    // [task_032] 扇区请求仲裁(层内): 扫描器直连 + 顶层仲裁回灌口。
    //   两源时序互斥(mount 期扫描器 / read 期 arb 回灌), 用 OR 选择即可,
    //   与原 file_streamer 直连时的二源 OR 语义一致(仅把 file 源换成 arb)。
    assign replay_req = scan_sector_req | arb_sector_req;
    assign replay_lba = scan_sector_req ? scan_sector_lba : arb_sector_lba;

    // [task_032] 回灌口应答: 直接镜像 replay 缓冲的输出(仅 arb 源使用;
    //   扫描器由层内 scanner 直连 replay, 不经本口)。
    assign arb_sector_busy       = replay_busy;
    assign arb_sector_valid      = replay_valid;
    assign arb_sector_byte       = replay_byte;
    assign arb_sector_byte_index = replay_byte_index;
    assign arb_sector_done       = replay_done;
    assign arb_sector_error      = replay_error;

    // ------------------------------------------------------------------
    // file_count = 4 槽 resource_valid 的 popcount
    // ------------------------------------------------------------------
    assign file_count = {4'd0, scan_resource_valid[0]} +
                        {4'd0, scan_resource_valid[1]} +
                        {4'd0, scan_resource_valid[2]} +
                        {4'd0, scan_resource_valid[3]};

    // ------------------------------------------------------------------
    // 查询口(1 拍延迟寄存, 与冻结接口一致)
    // ------------------------------------------------------------------
    function [87:0] slot_name;
        input [1:0] sel;
        reg [7:0] d;
        begin
            case (sel)
                2'd0:    d = "1";
                2'd1:    d = "2";
                2'd2:    d = "3";
                default: d = "4";
            endcase
            // 8.3 目录项名 11 字节: "PICn" + 4 空格 + "BMP"
            slot_name = {"PIC", d, "    ", "BMP"};
        end
    endfunction

    reg [87:0] q_name_r;
    reg [31:0] q_size_r;
    reg        q_bmp_r, q_wav_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_name_r <= 88'd0;
            q_size_r <= 32'd0;
            q_bmp_r  <= 1'b0;
            q_wav_r  <= 1'b0;
        end else if (query_index < file_count) begin
            case (query_index[1:0])
                2'd0: begin
                    q_name_r <= slot_name(2'd0);
                    q_size_r <= res0_size;
                    q_bmp_r  <= scan_resource_valid[0];
                end
                2'd1: begin
                    q_name_r <= slot_name(2'd1);
                    q_size_r <= res1_size;
                    q_bmp_r  <= scan_resource_valid[1];
                end
                2'd2: begin
                    q_name_r <= slot_name(2'd2);
                    q_size_r <= res2_size;
                    q_bmp_r  <= scan_resource_valid[2];
                end
                default: begin
                    q_name_r <= slot_name(2'd3);
                    q_size_r <= res3_size;
                    q_bmp_r  <= scan_resource_valid[3];
                end
            endcase
            q_wav_r <= 1'b0;
        end
    end
    assign query_name   = q_name_r;
    assign query_size   = q_size_r;
    assign query_is_bmp = q_bmp_r;
    assign query_is_wav = q_wav_r;

    // ------------------------------------------------------------------
    // 数据字出口: 字节流按大端序 4 字节打包, 第 4 字节拍产出一字; 文件尾
    // 不足 4 字节时右对齐补 0(与 009 流语义一致)。
    //
    // 节拍整形(ADOPT 集成修复): 米醋 replay 以 1 字节/clk 突发倒出整扇区,
    // 打包后即 1 字/4 拍的 128 字突发; 012 loader 输入 FIFO 仅 32 深且冻结
    // 接口无背压(满即静默丢字→stream_error, m06 实测)。本层加一级 128 字
    // (一扇区)弹性缓冲并以 1 字/64 拍匀速排出, 恢复"SPI 供字慢于 loader 消费"
    // 的原始不变量。突发排空 128×64=8192 拍 < 扇区供给周期([2026-09-21 提速]
    // div=2 时 ≈17300 拍: 523B×32 拍/B + FSM 字节间开销, 裕量 ≈2.1×;
    // 出口节奏 64 拍/字为硬编码常量, 与 SPI 分频无关——分频只影响本缓冲
    // 入口侧的供给周期), 容量与节奏均有结构裕量; 字内容/顺序/字数(ceil(size/4))
    // 不变, 仅节拍改变。
    // ------------------------------------------------------------------
    reg  [31:0] word_acc;
    // 文件读取期间索引/尺寸稳定; file_start在read_start受理后一拍送达,
    // 首个file_valid晚于元数据寄存, 将选槽/减法移出每字节FIFO写使能链。
    reg  [31:0] file_last_offset_r;
    reg         file_nonempty_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            file_last_offset_r <= 32'd0;
            file_nonempty_r    <= 1'b0;
        end else begin
            file_last_offset_r <= slot_size - 32'd1;
            file_nonempty_r    <= (slot_size != 32'd0);
        end
    end
    wire        byte_is_last = file_nonempty_r &&
                               (file_byte_offset == file_last_offset_r);
    wire        word_done  = file_valid &&
                             ((file_byte_offset[1:0] == 2'd3) || byte_is_last);
    wire [31:0] word_next =
        (file_byte_offset[1:0] == 2'd0) ? {file_byte,      word_acc[23:0]} :
        (file_byte_offset[1:0] == 2'd1) ? {word_acc[31:24], file_byte, word_acc[15:0]} :
        (file_byte_offset[1:0] == 2'd2) ? {word_acc[31:16], file_byte, word_acc[7:0]} :
                                          {word_acc[31:8],  file_byte};

    reg [31:0] wf_mem  [0:127];      // 一扇区字突发缓冲(128 字)
    reg [6:0]  wf_wptr, wf_rptr;
    reg [7:0]  wf_cnt;
    reg [5:0]  wf_gap;               // 排水节拍间隔计数(64 拍/字)

    wire       wf_push = word_done;
    wire       wf_pop  = (wf_cnt != 8'd0) && (wf_gap == 6'd0);

    // 单驱动规约: word_acc/wf_*/data_* 仅本 always 写; 胶水 FSM 只出
    // path_clr 单拍标志(TD HDL-8007 拒绝跨 always 多驱动, iverilog 仅宽容)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out   <= 32'd0;
            data_valid <= 1'b0;
            word_acc   <= 32'd0;
            wf_wptr    <= 7'd0;
            wf_rptr    <= 7'd0;
            wf_cnt     <= 8'd0;
            wf_gap     <= 6'd0;
        end else if (path_clr) begin
            data_out   <= 32'd0;
            data_valid <= 1'b0;
            word_acc   <= 32'd0;
            wf_wptr    <= 7'd0;
            wf_rptr    <= 7'd0;
            wf_cnt     <= 8'd0;
            wf_gap     <= 6'd0;
        end else begin
            data_valid <= 1'b0;
            // 入口: 打包字写入(突发期最多 128 字/扇区)
            if (file_valid) begin
                if (word_done) begin
                    wf_mem[wf_wptr] <= word_next;
                    wf_wptr   <= wf_wptr + 7'd1;
                    word_acc  <= 32'd0;
                end else begin
                    word_acc  <= word_next;
                end
            end
            // 计数(同拍一出一入抵消)
            case ({wf_push, wf_pop})
                2'b10:   wf_cnt <= wf_cnt + 8'd1;
                2'b01:   wf_cnt <= wf_cnt - 8'd1;
                default: wf_cnt <= wf_cnt;
            endcase
            // 出口: 1 字/64 拍匀速
            if (wf_pop) begin
                data_out   <= wf_mem[wf_rptr];
                data_valid <= 1'b1;
                wf_rptr    <= wf_rptr + 7'd1;
                wf_gap     <= 6'd63;
            end else if (wf_gap != 6'd0) begin
                wf_gap <= wf_gap - 6'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 胶水状态机: mount_start → scanner; read_start → streamer(互斥)
    // ------------------------------------------------------------------
    localparam [1:0] GS_IDLE  = 2'd0,
                     GS_MOUNT = 2'd1,
                     GS_READ  = 2'd2;

    reg [1:0] gstate;
    reg       path_clr;    // mount/read 接受拍: 清空打包/FIFO(单拍, 数据通路独驱)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gstate      <= GS_IDLE;
            scan_start  <= 1'b0;
            file_start  <= 1'b0;
            mount_busy  <= 1'b0;
            mount_done  <= 1'b0;
            mount_error <= 1'b0;
            read_busy   <= 1'b0;
            read_done   <= 1'b0;
            read_error  <= 1'b0;
            path_clr    <= 1'b0;
        end else begin
            scan_start <= 1'b0;
            file_start <= 1'b0;
            mount_done <= 1'b0;
            read_done  <= 1'b0;
            path_clr   <= 1'b0;

            case (gstate)
                GS_IDLE: begin
                    mount_busy <= 1'b0;
                    read_busy  <= 1'b0;
                    if (mount_start) begin
                        mount_busy  <= 1'b1;
                        mount_error <= 1'b0;
                        path_clr    <= 1'b1;
                        scan_start  <= 1'b1;
                        gstate      <= GS_MOUNT;
                    end else if (read_start) begin
                        read_busy  <= 1'b1;
                        read_error <= 1'b0;
                        path_clr   <= 1'b1;
                        if (read_index >= FILE_SLOTS) begin
                            // 索引越界防御: 立即收口报 read_error
                            read_done  <= 1'b1;
                            read_error <= 1'b1;
                        end else begin
                            file_start <= 1'b1;
                            gstate     <= GS_READ;
                        end
                    end
                end

                GS_MOUNT: begin
                    if (scan_done) begin
                        mount_busy  <= 1'b0;
                        mount_done  <= 1'b1;
                        mount_error <= (scan_fs_error != 8'h00);
                        gstate      <= GS_IDLE;
                    end
                end

                GS_READ: begin
                    if (file_done) begin
                        read_busy  <= 1'b0;
                        read_done  <= 1'b1;
                        read_error <= (file_fs_error != 8'h00);
                        gstate     <= GS_IDLE;
                    end
                end

                default: gstate <= GS_IDLE;
            endcase
        end
    end

    // 冻结接口端口保留: 端口值不消费(顶层传 16'd2 为 026 历史占位, 从未
    // 生效), 实际分频由本层 SPI_CLK_DIV_SIM 编译期常量决定(米醋字节引擎
    // 为编译期分频, 运行期端口值无法喂给参数)
    wire _unused = &{1'b0, spi_clk_div, 1'b0};

endmodule
