`timescale 1ns/1ps
// ============================================================================
// fat32_interval_reader — task_046 B2 冻结接口 1: 文件区间读取器(P1 双缓冲)
//
// 功能: 受理 [offset, length) 逻辑字节区间请求, 按 FAT 链跨簇定位,
//   只向字节口交付区间内字节(有序、文件偏移递增); 区间首尾按 512B 扇区
//   扩展读取, 越界字节内部丢弃; 一次至多一个在途。顺序前进的连续请求
//   直接从已推进链位续走(不重定位); 回退请求自动从链头重定位。
//
// P1 结构: 捕获引擎(定位/走链/收扇区)与消费引擎(按 byte_ready 放出)并行,
//   中间用 2 个扇区缓冲解耦 —— 一扇区在被消费的同时下一扇区已在捕获,
//   消除 B3 单缓冲"整扇区捕获 → 排空 → 再捕获"的串行等待。
//   存储写成 1024×8 的寄存器地址 + 寄存器输出形态以推断块 RAM(分布式 RAM
//   在当前 slice 占用下无预算再复制一份 512B)。
//
// 硬约束(与 B2 契约一致): 扇区只有整扇区收下且卡端无错(CRC 通过)才置 full,
//   未通过的扇区绝不作为有效数据放出; 两缓冲均占用时不再发起下一扇区请求;
//   SD 单扇区物理传输不可停(在途扇区必然收完)。
//
// FAT 走链与原 file_streamer 同码族(有界遍历 MAX_VISITED_CLUSTERS)。
// ============================================================================
module fat32_interval_reader #(
    parameter integer MAX_VISITED_CLUSTERS = 8192
) (
    input  wire        clk,
    input  wire        rst_n,

    // 卷几何(卷扫描锁存值, 装载期稳定)
    input  wire [7:0]  spc,
    input  wire [31:0] fat_start_lba,
    input  wire [31:0] data_start_lba,
    input  wire [31:0] max_cluster,
    input  wire [31:0] file_first_cluster,
    input  wire [31:0] file_size,

    // 区间请求(一次至多一个在途)
    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] req_offset,
    input  wire [31:0] req_length,

    // 字节流(区间首字节在先; byte_valid 持有至 byte_ready 受理)
    output reg         byte_valid,
    output reg  [7:0]  byte_data,
    input  wire        byte_ready,

    // 完成/错误
    output reg         ival_done,
    output reg  [7:0]  error,      // sticky 锁存首失败(load_start 外复位不可清)

    // 扇区事务口
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);
    localparam [7:0] E_NONE   = 8'h00;
    localparam [7:0] E_RANGE  = 8'h01;  // 非法区间(受理前拒绝, 不发卡)
    localparam [7:0] E_SECTOR = 8'h10;  // 卡/CRC 错误(streamer 同码)
    localparam [7:0] E_FAT_LOOP     = 8'h23;
    localparam [7:0] E_CLUSTER_RANGE= 8'h24;
    localparam [7:0] E_EARLY_EOC    = 8'h25;
    localparam [7:0] E_VISITED_EXH  = 8'h26;

    localparam [1:0] SV_IDLE = 2'd0,
                     SV_RUN  = 2'd1,
                     SV_DONE = 2'd2;   // done 单拍后多留一拍: req_ready 必在
                                       // ival_done 之后才升起(下游按此次序
                                       // 判定"本行字节不先于上行 done")

    // 捕获引擎: 定位 → (走 FAT) → 发扇区请求 → 收整扇区 → 等空位/停车
    localparam [2:0] CP_LOCATE     = 3'd0,
                     CP_FAT_REQ    = 3'd1,
                     CP_FAT_WAIT  = 3'd2,
                     CP_FAT_NEXT  = 3'd3,
                     CP_DATA_REQ  = 3'd4,
                     CP_DATA_RECV = 3'd5,
                     CP_STALL     = 3'd6,   // 目标缓冲未空(消费侧背压)
                     CP_PARK      = 3'd7;   // 本区间无需再捕获

    localparam [1:0] EM_NONE   = 2'd0,   // 等一个 full 缓冲
                     EM_SETTLE = 2'd1,   // 读地址已改, 等同步读出落定
                     EM_HOLD  = 2'd2;    // 字节呈现中(持有至受理)

    localparam integer CHAIN_W = $clog2(MAX_VISITED_CLUSTERS + 1);

    // ---------------------------------------------------------------- 会话
    reg [1:0]  sstate;
    reg [31:0] end_off;         // 区间末端(不含)
    reg        served;          // 区间内末字节已被受理

    // ------------------------------------------------------------ 捕获侧
    reg [2:0]  cstate;
    reg [31:0] cap_off;         // 下一待捕获扇区的文件基偏移(512 对齐)
    reg [31:0] cur_cluster;
    reg [31:0] file_clu_idx;    // 当前簇在文件内序号(0 起)
    reg [7:0]  sec_in_clu;
    reg [31:0] next_cluster;
    reg [CHAIN_W-1:0] chain_count;
    reg        chain_based;
    reg        cap_idx;         // 正在捕获的缓冲编号
    reg [9:0]  cap_cnt;         // 本扇区已收字节数
    reg        head_pending;    // 本区间首扇区需按 offset%512 丢头
    reg [8:0]  head_skip;       // 受理时锁存的头丢弃量(offset%512)

    reg [7:0]  fat_b0, fat_b1, fat_b2, fat_b3;

    // -------------------------------------------------------------- 缓冲
    reg [7:0]  sbuf [0:1023];
    reg        full0, full1;
    reg [9:0]  cnt0,  cnt1;     // 有效字节数(整扇区 512)
    reg [8:0]  skip0, skip1;    // 首扇区头丢弃量

    // ------------------------------------------------------------ 消费侧
    reg [1:0]  estate;
    reg        con_idx;
    reg [9:0]  ram_waddr;       // 写地址 {缓冲号, 扇区内偏移}(寄存器化)
    reg [9:0]  ram_raddr;       // 读地址 {缓冲号, 扇区内偏移}
    reg [7:0]  ram_q;           // 块 RAM 同步读出寄存器
    reg [9:0]  walk_left;       // 当前缓冲仍需走的位置数
    reg [31:0] cur_off;         // 下一个尚未服务的文件偏移(绝对)
    reg [1:0]  settle_cnt;

    // 移位工具(spc 恒 2 的幂)
    wire [3:0] spc_sh = (spc >= 8'd128) ? 4'd7 :
                        (spc >= 8'd64)  ? 4'd6 :
                        (spc >= 8'd32)  ? 4'd5 :
                        (spc >= 8'd16)  ? 4'd4 :
                        (spc >= 8'd8)   ? 4'd3 :
                        (spc >= 8'd4)   ? 4'd2 :
                        (spc >= 8'd2)   ? 4'd1 : 4'd0;
    wire [31:0] tgt_file_idx = cap_off >> (4'd9 + spc_sh);
    wire [31:0] tgt_sec_w    = (cap_off >> 9) & ({24'd0, spc} - 32'd1);
    wire [7:0]  tgt_sec_in   = tgt_sec_w[7:0];
    wire [31:0] clu_lba      = data_start_lba + ((cur_cluster - 32'd2) << spc_sh);
    wire [31:0] clu_base_off = file_clu_idx << (4'd9 + spc_sh);

    wire [31:0] req_base = {req_offset[31:9], 9'd0};

    // 受理守卫(33 位扩展溢出检查)
    wire [32:0] sum33    = {1'b0, req_offset} + {1'b0, req_length};
    wire        range_ok = (req_length != 32'd0) &&
                           (req_offset < file_size) &&
                           !sum33[32] && (sum33[31:0] <= file_size);
    assign req_ready = (sstate == SV_IDLE) && (error == E_NONE);

    // 缓冲元数据按编号取用
    wire       con_full   = con_idx ? full1 : full0;
    wire [9:0] con_cnt    = con_idx ? cnt1  : cnt0;
    wire [8:0] con_skip   = con_idx ? skip1 : skip0;
    wire       cap_full   = cap_idx ? full1 : full0;

    // done 与末字节同拍时计入该字节
    wire [9:0] cap_cnt_fin = cap_cnt + (sector_valid ? 10'd1 : 10'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sstate     <= SV_IDLE;
            byte_valid <= 1'b0;  byte_data <= 8'd0;
            ival_done  <= 1'b0;  error     <= E_NONE;
            sector_req <= 1'b0;  sector_lba <= 32'd0;
            served     <= 1'b0;  end_off   <= 32'd0;
            cstate     <= CP_LOCATE;
            cap_off    <= 32'd0; cur_cluster <= 32'd0;
            file_clu_idx <= 32'd0; sec_in_clu <= 8'd0;
            next_cluster <= 32'd0; chain_count <= {CHAIN_W{1'b0}};
            chain_based <= 1'b0;  cap_idx <= 1'b0;   cap_cnt <= 10'd0;
            head_pending <= 1'b0; head_skip <= 9'd0;
            full0 <= 1'b0;  full1 <= 1'b0;
            cnt0  <= 10'd0; cnt1  <= 10'd0;
            skip0 <= 9'd0;  skip1 <= 9'd0;
            estate <= EM_NONE;  con_idx <= 1'b0;
            ram_waddr <= 10'd0; ram_raddr <= 10'd0;
            walk_left <= 10'd0; cur_off <= 32'd0; settle_cnt <= 2'd0;
            fat_b0 <= 8'd0; fat_b1 <= 8'd0; fat_b2 <= 8'd0; fat_b3 <= 8'd0;
        end else if (error == E_NONE) begin
            // sticky 错误后两引擎就地停泊(在途扇区的物理传输由卡端走完),
            // 只等外部复位 —— 不把半截数据当作有效放出。
            ival_done  <= 1'b0;
            sector_req <= 1'b0;

            case (sstate)
            // ------------------------------------------------------------
            SV_IDLE: begin
                if (req_valid) begin
                    if (!range_ok) begin
                        error <= E_RANGE;              // 受理前拒绝, 不动卡
                    end else begin
                        // 头区间从当前文件首簇定位, 避免上一文件仅读头后保留旧簇。
                        if (!chain_based || (req_base == 32'd0) ||
                            (req_base < clu_base_off)) begin
                            cur_cluster  <= file_first_cluster;
                            file_clu_idx <= 32'd0;
                            chain_count  <= {CHAIN_W{1'b0}};
                            chain_based  <= 1'b1;
                        end
                        cur_off      <= req_offset;
                        end_off      <= req_offset + req_length;
                        cap_off      <= req_base;
                        head_skip    <= req_offset[8:0];
                        head_pending <= 1'b1;
                        cap_idx      <= 1'b0;
                        con_idx      <= 1'b0;
                        cap_cnt      <= 10'd0;
                        full0        <= 1'b0;  full1 <= 1'b0;
                        estate       <= EM_NONE;
                        byte_valid   <= 1'b0;
                        served       <= 1'b0;
                        cstate       <= CP_LOCATE;
                        sstate       <= SV_RUN;
                    end
                end
            end
            // ------------------------------------------------------------
            SV_RUN: begin
                // =================== 捕获引擎(与消费并行) ===================
                case (cstate)
                    CP_LOCATE: begin
                        if (cap_off >= end_off) begin
                            cstate <= CP_PARK;                    // 本区间读够了
                        end else if (cap_full) begin
                            cstate <= CP_STALL;                   // 目标缓冲未空
                        end else if ((cur_cluster < 32'd2) || (cur_cluster > max_cluster) ||
                                     (spc == 8'd0)) begin
                            error <= E_CLUSTER_RANGE;
                        end else if (file_clu_idx == tgt_file_idx) begin
                            sec_in_clu <= tgt_sec_in;
                            cstate     <= CP_DATA_REQ;
                        end else begin
                            cstate <= CP_FAT_REQ;
                        end
                    end
                    CP_STALL: begin
                        // 消费侧腾出目标缓冲后续走; 区间已读够则转停车判定
                        if (!cap_full || (cap_off >= end_off)) cstate <= CP_LOCATE;
                    end
                    CP_PARK: begin
                        // 等消费侧收尾(完成判定见下)
                    end
                    // ------------------- FAT 走链(与 B3 同码族) ----------------
                    CP_FAT_REQ: if (!sector_busy) begin
                        sector_lba <= fat_start_lba + (cur_cluster >> 7);
                        sector_req <= 1'b1;
                        cstate     <= CP_FAT_WAIT;
                    end
                    CP_FAT_WAIT: begin
                        if (sector_valid) begin
                            if (sector_byte_index == {cur_cluster[6:0], 2'b00})
                                fat_b0 <= sector_byte;
                            else if (sector_byte_index == ({cur_cluster[6:0], 2'b00} + 9'd1))
                                fat_b1 <= sector_byte;
                            else if (sector_byte_index == ({cur_cluster[6:0], 2'b00} + 9'd2))
                                fat_b2 <= sector_byte;
                            else if (sector_byte_index == ({cur_cluster[6:0], 2'b00} + 9'd3))
                                fat_b3 <= sector_byte;
                        end
                        if (sector_done) begin
                            if (sector_error != 8'd0) error <= E_SECTOR;
                            else begin
                                next_cluster <= {4'd0, fat_b3[3:0], fat_b2, fat_b1, fat_b0};
                                cstate       <= CP_FAT_NEXT;
                            end
                        end
                    end
                    CP_FAT_NEXT: begin
                        if (next_cluster[27:0] >= 28'hffffff8)
                            error <= E_EARLY_EOC;
                        else if (next_cluster[27:0] < 28'd2 ||
                                 {4'd0, next_cluster[27:0]} > max_cluster)
                            error <= E_CLUSTER_RANGE;
                        else if (chain_count >= MAX_VISITED_CLUSTERS[CHAIN_W-1:0])
                            error <= E_VISITED_EXH;
                        else if (next_cluster[27:0] == cur_cluster[27:0])
                            error <= E_FAT_LOOP;
                        else begin
                            cur_cluster  <= next_cluster;
                            file_clu_idx <= file_clu_idx + 32'd1;
                            chain_count  <= chain_count + 1'b1;
                            cstate       <= CP_LOCATE;
                        end
                    end
                    // ----------------------- 数据扇区捕获 ---------------------
                    CP_DATA_REQ: if (!sector_busy) begin
                        sector_lba <= clu_lba + {24'd0, sec_in_clu};
                        sector_req <= 1'b1;
                        ram_waddr  <= {cap_idx, 9'd0};
                        cap_cnt    <= 10'd0;
                        cstate     <= CP_DATA_RECV;
                    end
                    CP_DATA_RECV: begin
                        // 供给不可停: 整扇区无条件写入目标缓冲
                        if (sector_valid) begin
                            sbuf[ram_waddr] <= sector_byte;
                            ram_waddr <= {cap_idx, ram_waddr[8:0] + 9'd1};
                            cap_cnt   <= cap_cnt + 10'd1;
                        end
                        if (sector_done) begin
                            if (sector_error != 8'd0) begin
                                error <= E_SECTOR;            // 残扇区不置 full
                            end else begin
                                // 只有 CRC 通过的整扇区才交予消费侧
                                if (!cap_idx) begin
                                    full0 <= 1'b1;  cnt0 <= cap_cnt_fin;
                                    skip0 <= head_pending ? head_skip : 9'd0;
                                end else begin
                                    full1 <= 1'b1;  cnt1 <= cap_cnt_fin;
                                    skip1 <= head_pending ? head_skip : 9'd0;
                                end
                                head_pending <= 1'b0;
                                cap_off <= cap_off + 32'd512;
                                cap_idx <= ~cap_idx;
                                cstate  <= CP_LOCATE;
                            end
                        end
                    end
                    default: cstate <= CP_LOCATE;
                endcase

                // =================== 消费引擎(与捕获并行) ===================
                case (estate)
                    EM_NONE: begin
                        if (con_full && !served) begin
                            // 直接落到该缓冲的首个有效位置(不逐字节空走)
                            ram_raddr  <= {con_idx, con_skip};
                            walk_left  <= con_cnt - {1'b0, con_skip};
                            settle_cnt <= 2'd2;
                            estate     <= EM_SETTLE;
                        end
                    end
                    EM_SETTLE: begin
                        if (settle_cnt == 2'd0) begin
                            byte_valid <= 1'b1;
                            byte_data  <= ram_q;
                            estate     <= EM_HOLD;
                        end else begin
                            settle_cnt <= settle_cnt - 2'd1;
                        end
                    end
                    EM_HOLD: begin
                        if (byte_ready) begin
                            // 受理该字节: 前进一个位置(呈现口先释放)
                            byte_valid <= 1'b0;
                            cur_off    <= cur_off + 32'd1;
                            if (cur_off == (end_off - 32'd1)) begin
                                served    <= 1'b1;
                                estate    <= EM_NONE;
                                walk_left <= walk_left - 10'd1;
                            end else if (walk_left == 10'd1) begin
                                // 本缓冲走完: 交还捕获侧并换到另一块
                                if (!con_idx) full0 <= 1'b0;
                                else          full1 <= 1'b0;
                                con_idx  <= ~con_idx;
                                estate   <= EM_NONE;
                            end else begin
                                ram_raddr <= ram_raddr + 10'd1;
                                walk_left <= walk_left - 10'd1;
                                settle_cnt <= 2'd1;
                                estate    <= EM_SETTLE;
                            end
                        end
                    end
                    default: estate <= EM_NONE;
                endcase

                // ======================= 区间完成判定 =======================
                // 区间内末字节已受理 && 捕获侧已停车(无未决请求/无在途扇区)
                // && 呈现口已释放。停车前在途扇区必然收完(物理传输不可停)。
                if (served && !byte_valid && (cstate == CP_PARK)) begin
                    ival_done <= 1'b1;
                    served    <= 1'b0;
                    full0     <= 1'b0;  full1 <= 1'b0;
                    estate    <= EM_NONE;
                    sstate    <= SV_DONE;
                end
            end
            SV_DONE: sstate <= SV_IDLE;
            default: sstate <= SV_IDLE;
            endcase
        end
    end

    // 块 RAM 同步读: 寄存器地址 + 寄存器输出(无条件每拍读, 便于 BRAM 推断)
    always @(posedge clk) begin
        ram_q <= sbuf[ram_raddr];
    end

endmodule
