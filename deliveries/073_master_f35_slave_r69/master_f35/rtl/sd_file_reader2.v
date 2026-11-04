`timescale 1ns / 1ps
// ============================================================================
// sd_file_reader2 — 两个上下文分时共用一套 extent 遍历与块池读出的文件读
//
// 上下文 0 = 图片(BMP), 1 = 音乐(WAV)。每个上下文按自己的 extent 表(FAT 表的
// bank = 上下文号)顺序以 CMD18 读文件, 输出 32 位大端字流, 字带上下文标记。
// 工作寄存器只有一套; 另一上下文的进度存在影子寄存器里, 切换时整套互换。
// 切换只发生在两次 CMD18 之间且数据侧已排空(块池空、无在途字), 所以字流按
// 上下文成段输出, 下游按 out_ctx 分发即可。
// 调度: 上下文 1 在 room1(音频缓冲有余量)时优先, 每次只读 RUN1 块(马上被消耗);
//   否则服务上下文 0, 每次 RUN0 块。hold=1 时不发新读(SD 让给 FAT 查找/视频)。
// 文件尾: 最后一块按文件长度截止, 再送 PAD 个 0 字(推出下游滞留字节), 然后 done。
// start[c] 只在 busy[c]=0 时发出(调用方约定); 正在读的上下文只能 cancel。
// cancel[c]: 放弃该上下文; 若它正在读, 等本次 CMD18 结束, 其余块直接归还。
// 读错误: 从出错块重读(已送出的块不重复)。
// ============================================================================
module sd_file_reader2 #(
    parameter integer EXT_AW = 7,
    parameter [15:0]  RUN0   = 16'd32,
    parameter [15:0]  RUN1   = 16'd4,
    parameter [3:0]   PAD    = 4'd4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  start,                // 单拍, 每位一个上下文
    input  wire [1:0]  cancel,
    input  wire [31:0] file_size,            // 与 start 同拍有效
    input  wire [EXT_AW:0] n_ext,
    input  wire        room1,                // 上下文 1 下游可吸收 RUN1 块
    input  wire        hold,
    output wire [1:0]  busy,
    output reg  [1:0]  done,
    output wire        idle,                 // 无读事务在途且数据侧已排空

    output wire [EXT_AW:0]   ext_raddr,      // {bank=上下文, 序号}
    input  wire [31:0] ext_lba,
    input  wire [31:0] ext_blocks,

    output reg         st_start,
    output reg  [31:0] st_lba,
    output reg  [15:0] st_count,
    input  wire        st_busy,
    input  wire        st_done,
    input  wire        st_err,
    input  wire [15:0] st_blocks,

    input  wire [3:0]  pool_count,
    output reg  [6:0]  pool_raddr,
    input  wire [31:0] pool_rdata,
    output reg         pool_release,

    output reg         out_valid,
    output reg  [31:0] out_data,
    output wire        out_ctx,
    input  wire        out_ready
);
    // ---------------- 上下文: 工作套(cur) + 影子套(oth) ----------------
    reg        cur;                          // 当前上下文号
    reg        a_act, b_act;                 // 工作 / 影子 上下文有文件在读
    reg        a_rqd, b_rqd;                 // 请求侧已结束(只剩数据侧收尾)
    reg        a_ld,  b_ld;                  // 需要重新载入 extent
    reg [EXT_AW:0] a_ei, b_ei, a_n, b_n;
    reg [31:0] a_lba, b_lba, a_eleft, b_eleft, a_pleft, b_pleft, a_bytes, b_bytes;
    reg [3:0]  a_pad, b_pad;
    assign busy     = cur ? {a_act, b_act} : {b_act, a_act};
    assign out_ctx  = cur;
    assign ext_raddr = {cur, a_ei[EXT_AW-1:0]};

    // ---------------- 请求侧 ----------------
    localparam [2:0] Q_IDLE = 3'd0, Q_LD = 3'd1, Q_LD2 = 3'd2, Q_LD3 = 3'd3, Q_ISSUE = 3'd4, Q_RUN = 3'd5, Q_SW = 3'd6;
    reg [2:0]  qs;
    reg [31:0] x_lba, x_blk;
    reg        xc_pend;                      // 当前上下文的取消请求(等本次 CMD18 结束)

    // ---------------- 数据侧 ----------------
    reg        rd_pend, rd_pend2;
    reg [7:0]  widx;
    reg        skid_v;
    reg [31:0] skid;
    wire       out_free = !out_valid || out_ready;
    wire       drained  = (pool_count == 0) && (widx == 0) && !rd_pend && !rd_pend2 && !skid_v && !out_valid;
    assign idle = (qs != Q_RUN) && !st_busy && drained;

    // 下一次服务哪个上下文: 1 有余量优先, 否则 0
    wire cur_want = a_act && !a_rqd && (cur ? room1 : 1'b1);
    wire oth_want = b_act && !b_rqd && (cur ? 1'b1 : room1);
    wire prefer_oth = oth_want && (!cur_want || !cur);   // 当前是 0 且 1 想要 -> 让给 1
    wire [15:0] run_max = cur ? RUN1 : RUN0;

    wire [31:0] fblocks = (file_size + 32'd511) >> 9;
    wire [31:0] be = {pool_rdata[7:0], pool_rdata[15:8], pool_rdata[23:16], pool_rdata[31:24]};
    // 当前上下文完成: 请求侧结束且数据侧排空 -> 补 PAD 零字
    wire cur_tail = a_act && a_rqd && drained && out_free;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur <= 1'b0; qs <= Q_IDLE; x_lba <= 0; x_blk <= 0; xc_pend <= 1'b0;
            a_act <= 0; b_act <= 0; a_rqd <= 0; b_rqd <= 0; a_ld <= 0; b_ld <= 0;
            a_ei <= 0; b_ei <= 0; a_n <= 0; b_n <= 0; a_lba <= 0; b_lba <= 0; a_eleft <= 0; b_eleft <= 0;
            a_pleft <= 0; b_pleft <= 0; a_bytes <= 0; b_bytes <= 0; a_pad <= 0; b_pad <= 0;
            st_start <= 1'b0; st_lba <= 0; st_count <= 0; done <= 2'b00;
            rd_pend <= 0; rd_pend2 <= 0; widx <= 0; skid_v <= 0; skid <= 0;
            pool_raddr <= 0; pool_release <= 1'b0; out_valid <= 1'b0; out_data <= 0;
        end else begin
            st_start <= 1'b0; done <= 2'b00; pool_release <= 1'b0;
            if (out_valid && out_ready) out_valid <= 1'b0;
            rd_pend2 <= rd_pend; rd_pend <= 1'b0;

            // ---- 启动 / 取消(按上下文号落到工作套或影子套) ----
            if (cancel[cur] && a_act) begin
                // 当前上下文: 正在读则等 CMD18 结束, 否则立即生效
                if (qs == Q_RUN) xc_pend <= 1'b1;
                else begin a_act <= 1'b0; a_rqd <= 1'b0; a_bytes <= 0; a_pad <= 0; skid_v <= 1'b0; out_valid <= 1'b0; end
            end else if (start[cur]) begin
                a_act <= 1'b1; a_rqd <= 1'b0; a_ld <= 1'b1; a_ei <= 0; a_n <= n_ext;
                a_pleft <= fblocks; a_bytes <= file_size; a_pad <= PAD; a_eleft <= 0;
            end
            if (start[!cur]) begin
                b_act <= 1'b1; b_rqd <= 1'b0; b_ld <= 1'b1; b_ei <= 0; b_n <= n_ext;
                b_pleft <= fblocks; b_bytes <= file_size; b_pad <= PAD; b_eleft <= 0;
            end else if (cancel[!cur]) begin
                b_act <= 1'b0; b_rqd <= 1'b0;
            end

            // ---- 请求侧 ----
            case (qs)
            Q_IDLE:  if (!hold) begin
                         if (prefer_oth) qs <= Q_SW;
                         else if (cur_want) qs <= a_ld ? Q_LD : Q_ISSUE;
                     end
            // 换上下文: 数据侧排空后整套互换
            // 同拍有启动/取消时推迟一拍, 避免与整套互换写同一组寄存器
            Q_SW:    if (drained && !st_busy && start == 2'b00 && cancel == 2'b00) begin
                         cur <= !cur;
                         {a_act, b_act} <= {b_act, a_act}; {a_rqd, b_rqd} <= {b_rqd, a_rqd}; {a_ld, b_ld} <= {b_ld, a_ld};
                         {a_ei, b_ei} <= {b_ei, a_ei}; {a_n, b_n} <= {b_n, a_n}; {a_lba, b_lba} <= {b_lba, a_lba};
                         {a_eleft, b_eleft} <= {b_eleft, a_eleft}; {a_pleft, b_pleft} <= {b_pleft, a_pleft};
                         {a_bytes, b_bytes} <= {b_bytes, a_bytes}; {a_pad, b_pad} <= {b_pad, a_pad};
                         qs <= Q_IDLE;
                     end
            Q_LD:    qs <= Q_LD2;                                  // extent 读口 1 拍
            Q_LD2:   begin x_lba <= ext_lba; x_blk <= ext_blocks; qs <= Q_LD3; end
            Q_LD3:   begin a_lba <= x_lba; a_eleft <= (x_blk > a_pleft) ? a_pleft : x_blk; a_ld <= 1'b0; qs <= Q_ISSUE; end
            Q_ISSUE: if (!a_act) qs <= Q_IDLE;
                     else if (a_pleft == 0) begin a_rqd <= 1'b1; qs <= Q_IDLE; end
                     else if (a_eleft == 0) begin
                         if (a_ei + 1'b1 == a_n) begin a_rqd <= 1'b1; qs <= Q_IDLE; end
                         else begin a_ei <= a_ei + 1'b1; a_ld <= 1'b1; qs <= Q_LD; end
                     end else if (hold || prefer_oth || !cur_want) qs <= Q_IDLE;
                     else if (!st_busy) begin
                         st_start <= 1'b1; st_lba <= a_lba;
                         st_count <= (a_eleft > {16'd0, run_max}) ? run_max : a_eleft[15:0];
                         qs <= Q_RUN;
                     end
            Q_RUN:   if (st_done) begin
                         a_lba <= a_lba + st_blocks; a_eleft <= a_eleft - st_blocks; a_pleft <= a_pleft - st_blocks;
                         if (xc_pend) begin xc_pend <= 1'b0; a_act <= 1'b0; a_rqd <= 1'b0; a_bytes <= 0; a_pad <= 0; end
                         qs <= Q_IDLE;
                     end
            default: qs <= Q_IDLE;
            endcase

            // ---- 数据侧: 读返回(文件尾之后的字节不送出) ----
            if (rd_pend2) begin
                if (a_bytes != 0 && a_act && !xc_pend) begin
                    if (out_free && !(out_valid && !out_ready)) begin out_valid <= 1'b1; out_data <= be; end
                    else begin skid_v <= 1'b1; skid <= be; end
                    a_bytes <= (a_bytes > 32'd4) ? a_bytes - 32'd4 : 32'd0;
                end
            end else if (skid_v && out_free) begin
                skid_v <= 1'b0; out_valid <= 1'b1; out_data <= skid;
            end
            // 块内读满 128 字, 或已无有效字(尾块填充/取消)时归还该块
            // 归还脉冲在下一拍才更新块池队首/数量; 该拍不能据旧 count 发起下一读。
            if ((pool_count != 0) && !pool_release && (widx != 8'd128) && !rd_pend && !rd_pend2 && !skid_v &&
                out_free && a_bytes != 0 && a_act && !xc_pend) begin
                pool_raddr <= widx[6:0]; rd_pend <= 1'b1; widx <= widx + 8'd1;
            end else if ((widx == 8'd128 || ((a_bytes == 0 || !a_act || xc_pend) && pool_count != 0)) &&
                         !rd_pend && !rd_pend2 && !pool_release) begin
                pool_release <= 1'b1; widx <= 0;
            end

            // ---- 收尾: 补 PAD 个 0 字 -> done ----
            if (cur_tail && qs != Q_SW) begin
                if (a_pad != 0) begin out_valid <= 1'b1; out_data <= 32'd0; a_pad <= a_pad - 4'd1; end
                else begin a_act <= 1'b0; a_rqd <= 1'b0; done[cur] <= 1'b1; end
            end
        end
    end
endmodule
