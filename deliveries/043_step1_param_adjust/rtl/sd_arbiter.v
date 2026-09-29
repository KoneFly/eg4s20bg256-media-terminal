`timescale 1ns/1ps
// ============================================================================
// sd_arbiter — 三源整扇区事务仲裁器 (task_032 新写)
//
// 功能:
//   三个同构扇区请求源共享一个 SD 扇区读链, 按固定优先级做"整扇区事务"仲裁。
//   一次事务的定义域 = 某源拉 req 被授权, 到该源收到 done 或 error 为止。
//   事务期间**不可抢占**——更高优先级源中途拉 req 也必须排队等待, 从而保证
//   512 字节扇区数据的原子性(不会出现两个源的字节流交织)。
//
// 源端口族(三源同构, N = 0/1/2):
//   sN_req        源请求一个扇区事务(应保持到 busy 拉高或被授权)
//   sN_lba[31:0]  请求扇区号(随 req 同拍稳定)
//   sN_busy       输出: 该源当前"忙"(已授权事务在途 或 上电后 SD 链尚未 init_ready)
//   sN_done       输出: 该源事务结束脉冲(成功或失败均给)
//   sN_valid      输出: 该源字节有效(仅授权期间可能为高)
//   sN_byte[7:0]  输出: 该源当前字节
//   sN_byte_index 输出: 该源当前字节在扇区内的偏移
//   sN_error[7:0] 输出: 该源事务错误码(0 = 无错)
//
// 仲裁优先级(硬要求, INTERFACE_SPEC §2):
//   源0(显示加载) > 源1(WAV 流) > 源2(扫描器)
//   依据: 显示加载处于人眼可见关键路径, 不可因 WAV/扫描器而阻塞;
//         扫描器仅挂载期活动, 可容忍排队延迟。
//
// 关键设计约定:
//   * grant 寄存器在事务期间保持, 只在 done/error 拍释放 —— 抢占禁令的实现
//     载体。若改成每拍重算优先级, 高优先级源中途 req 会立刻改写 grant,
//     造成事务撕裂(m1 变异靶点)。
//   * 未授权源 busy 必须拉高(规则 4): 防止未授权源误判空闲、重复发 req
//     导致自己的请求丢失或被覆盖。因此 busy_* 在"已授权"与"有等待请求"
//     两种情况下都为真。
//   * **sN_req 是单拍脉冲**(既有源 fat32_file_streamer / wav_pcm_streamer 的
//     实测契约: ST_DATA_REQ 中 `if (!sector_busy) sector_req<=1;` 只维持
//     一拍)。因此"授权时 req 已经落下"是**正常现象**, 绝不能据此撤销授权。
//     一旦发出 sd_req, 该事务即被 reader 捕获(负沿/当拍捕获均可), 必须
//     无条件跑完到 done/error。早期版本用 `req_pending && !g_req && !sd_busy`
//     做撤销, 会在 sd_busy 尚未拉高的那一拍(reader 需要 1 拍才进 ST_ISSUE)
//     误杀事务, 导致请求丢失、源永久等待 —— 这是 032 集成中的真实死锁根因。
//   * 单拍脉冲必须被**锁存到授权为止**(sN_pend + sN_pend_lba, 见下)。源侧把
//     !busy 当作"请求已受理"随即进入 WAIT 死等 done; 若脉冲落在非空闲拍而不被
//     记住, 请求即静默丢失、源永久停等 —— 这是 032 上板实测"WAV 播放中切图
//     ⇒ 音频停摆"的根因(显示加载期仲裁器几乎全程在途, 音频侧脉冲必然撞在
//     在途窗口内)。
//   * 输出到 reader 的 sd_req 只在 grant 拍拉高一次; 采用
//     "grant 保持 + req 单次拉高由 reader 捕获"的握手形态, 与
//     sd_spi_sector_reader / sd_sector_replay_buffer 既有约定一致。
// ============================================================================

module sd_arbiter (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 源 0: 显示加载 (fat32_file_streamer 侧, 最高优先级) ----
    input  wire        s0_req,
    input  wire [31:0] s0_lba,
    output reg         s0_busy,
    output reg         s0_done,
    output reg         s0_valid,
    output reg  [7:0]  s0_byte,
    output reg  [8:0]  s0_byte_index,
    output reg  [7:0]  s0_error,

    // ---- 源 1: WAV 流 (wav_pcm_streamer 侧, 次优先级) ----
    input  wire        s1_req,
    input  wire [31:0] s1_lba,
    output reg         s1_busy,
    output reg         s1_done,
    output reg         s1_valid,
    output reg  [7:0]  s1_byte,
    output reg  [8:0]  s1_byte_index,
    output reg  [7:0]  s1_error,

    // ---- 源 2: 卷扫描器 (仅挂载期活动, 最低优先级) ----
    input  wire        s2_req,
    input  wire [31:0] s2_lba,
    output reg         s2_busy,
    output reg         s2_done,
    output reg         s2_valid,
    output reg  [7:0]  s2_byte,
    output reg  [8:0]  s2_byte_index,
    output reg  [7:0]  s2_error,

    // ---- 仲裁输出 → SD 扇区读链 ----
    output reg         sd_req,
    output reg  [31:0] sd_lba,
    input  wire        sd_busy,
    input  wire        sd_done,
    input  wire        sd_valid,
    input  wire [7:0]  sd_byte,
    input  wire [8:0]  sd_byte_index,
    input  wire [7:0]  sd_error
);

    localparam [1:0] G_NONE = 2'd0,
                     G_S0   = 2'd1,
                     G_S1   = 2'd2,
                     G_S2   = 2'd3;

    reg [1:0] grant;

    // ------------------------------------------------------------------
    // 单拍请求锁存(文件头契约的实现载体)
    //   两个真实源都只在 1 拍内拉高 sN_req:
    //     fat32_file_streamer  ST_DATA_REQ/ST_FAT_REQ: `if (!sector_busy)
    //                            sector_req<=1;`(默认每拍清零, 随后进 WAIT 死等 done)
    //     wav_pcm_streamer     sd_req = (wstate==WS_REQ) && !wr_pause, 而
    //                            sN_busy 比 sN_req 晚一拍 ⇒ WS_REQ 只停留 1 拍
    //   若该拍仲裁器非空闲(在途事务/握手期), 下方授权分支不成立, 而源已按
    //   "!busy 即已受理"的假设进入 WAIT ⇒ **请求被静默丢弃, 源永久停等**。
    //   显示加载期仲裁器几乎全程在途(1801 扇区背靠背), 故音频侧的单拍脉冲
    //   必然落在在途窗口内 —— 这就是"播放中切图 ⇒ WAV 停摆"的机制。
    //   锁存脉冲(连同其 LBA)直到被授权, 使契约成立; 未争用时行为逐拍不变。
    //   锁存按 **sN_req 上升沿**触发, 不是按电平: 电平型请求(源把 req 保持到
    //   done)本就由 win_req 直接授权, 若也锁存会在源放下 req 之后多出一笔
    //   没人接收的"孤儿事务"。上升沿语义 = "一次新的扇区请求", 与两个真实源
    //   每扇区发一拍脉冲的形态一一对应, 且电平型请求的既有行为逐拍不变。
    // ------------------------------------------------------------------
    reg        s0_pend, s1_pend, s2_pend;
    reg [31:0] s0_pend_lba, s1_pend_lba, s2_pend_lba;
    reg        s0_req_d, s1_req_d, s2_req_d;

    wire s0_rise = s0_req && !s0_req_d;
    wire s1_rise = s1_req && !s1_req_d;
    wire s2_rise = s2_req && !s2_req_d;

    wire s0_want = s0_req || s0_pend;
    wire s1_want = s1_req || s1_pend;
    wire s2_want = s2_req || s2_pend;

    // ------------------------------------------------------------------
    // 优先级选择: 源0 > 源1 > 源2, 仅在 grant 空闲时生效
    // ------------------------------------------------------------------
    wire        win_req;
    reg  [31:0] win_lba;
    reg  [1:0]  win_grant;

    always @* begin
        if (s0_want) begin
            win_grant = G_S0;
            win_lba   = s0_req ? s0_lba : s0_pend_lba;
        end else if (s1_want) begin
            win_grant = G_S1;
            win_lba   = s1_req ? s1_lba : s1_pend_lba;
        end else if (s2_want) begin
            win_grant = G_S2;
            win_lba   = s2_req ? s2_lba : s2_pend_lba;
        end else begin
            win_grant = G_NONE;
            win_lba   = 32'd0;
        end
    end
    assign win_req = (win_grant != G_NONE);

    // ------------------------------------------------------------------
    // 事务状态: 已授权但 reader 尚未 busy 拉高 → 还在请求握手
    // ------------------------------------------------------------------
    reg req_pending;   // 1 = 已出 sd_req, 等 sd_busy 确认事务启动
    reg in_txn;        // 1 = reader 已 busy, 事务在途, 禁止抢占

    wire idle_sel = (grant == G_NONE) && !req_pending && !in_txn;
    wire do_grant = idle_sel && win_req;
    wire g_s0     = do_grant && (win_grant == G_S0);
    wire g_s1     = do_grant && (win_grant == G_S1);
    wire g_s2     = do_grant && (win_grant == G_S2);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_pend     <= 1'b0;
            s1_pend     <= 1'b0;
            s2_pend     <= 1'b0;
            s0_req_d    <= 1'b0;
            s1_req_d    <= 1'b0;
            s2_req_d    <= 1'b0;
            s0_pend_lba <= 32'd0;
            s1_pend_lba <= 32'd0;
            s2_pend_lba <= 32'd0;
        end else begin
            s0_req_d <= s0_req;
            s1_req_d <= s1_req;
            s2_req_d <= s2_req;
            s0_pend  <= (s0_rise || s0_pend) && !g_s0;
            s1_pend  <= (s1_rise || s1_pend) && !g_s1;
            s2_pend  <= (s2_rise || s2_pend) && !g_s2;
            if (s0_rise) s0_pend_lba <= s0_lba;
            if (s1_rise) s1_pend_lba <= s1_lba;
            if (s2_rise) s2_pend_lba <= s2_lba;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant       <= G_NONE;
            req_pending <= 1'b0;
            in_txn      <= 1'b0;
            sd_req      <= 1'b0;
            sd_lba      <= 32'd0;
        end else begin
            sd_req <= 1'b0;

            // ---- 事务终结: done 或 error(非零) ----
            if (in_txn && (sd_done || (sd_error != 8'h00))) begin
                in_txn      <= 1'b0;
                req_pending <= 1'b0;
                grant       <= G_NONE;
            end
            // ---- 握手确认: reader 接受请求(捕获 sd_req 后拉起 busy) ----
            else if (req_pending && sd_busy) begin
                req_pending <= 1'b0;
                in_txn      <= 1'b1;
            end
            // ---- 空闲: 按优先级授权并发起 sd_req ----
            else if (do_grant) begin
                grant       <= win_grant;
                sd_req      <= 1'b1;
                sd_lba      <= win_lba;
                req_pending <= 1'b1;
            end
            // ---- 已发出 sd_req 但源 req 已落(单拍脉冲)且 reader 尚未 busy:
            //      仍保持 req_pending, 等下一拍 sd_busy 确认。绝不撤销 ——
            //      reader 已在 sd_req 拍捕获事务, 撤销会造成"孤儿事务"
            //      (reader 干活但无人收 done) 与源侧永久等待。
            //      (见文件头 "sN_req 是单拍脉冲" 说明)
        end
    end

    // ------------------------------------------------------------------
    // 输出解复用: 仅授权源看到 reader 的字节流/完成/错误
    // 未授权源: valid 恒 0, error 恒 0(避免误报), done 恒 0
    // ------------------------------------------------------------------
    wire g_val = sd_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_done <= 1'b0; s0_valid <= 1'b0; s0_byte <= 8'd0;
            s0_byte_index <= 9'd0; s0_error <= 8'd0;
            s1_done <= 1'b0; s1_valid <= 1'b0; s1_byte <= 8'd0;
            s1_byte_index <= 9'd0; s1_error <= 8'd0;
            s2_done <= 1'b0; s2_valid <= 1'b0; s2_byte <= 8'd0;
            s2_byte_index <= 9'd0; s2_error <= 8'd0;
        end else begin
            // 默认: 单拍脉冲与流信号清零, 仅授权源跟随
            s0_done  <= (grant == G_S0) && sd_done;
            s1_done  <= (grant == G_S1) && sd_done;
            s2_done  <= (grant == G_S2) && sd_done;

            s0_valid <= (grant == G_S0) && g_val;
            s1_valid <= (grant == G_S1) && g_val;
            s2_valid <= (grant == G_S2) && g_val;

            if ((grant == G_S0) && g_val) begin
                s0_byte       <= sd_byte;
                s0_byte_index <= sd_byte_index;
            end
            if ((grant == G_S1) && g_val) begin
                s1_byte       <= sd_byte;
                s1_byte_index <= sd_byte_index;
            end
            if ((grant == G_S2) && g_val) begin
                s2_byte       <= sd_byte;
                s2_byte_index <= sd_byte_index;
            end

            // 错误码: 事务终结拍锁存; 未授权源保持 0
            if (grant == G_S0) s0_error <= sd_error;
            if (grant == G_S1) s1_error <= sd_error;
            if (grant == G_S2) s2_error <= sd_error;
        end
    end

    // ------------------------------------------------------------------
    // busy 输出(规则 4): 已授权在途 或 有等待请求 或 已锁存待授权 或 握手期
    //   → 均报忙。含 sN_pend 是必要的: 单拍脉冲落下后源只能靠 busy 判断
    //   "我的请求还在队列里", 否则会在未受理时误判空闲而重复发 req。
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_busy <= 1'b0;
            s1_busy <= 1'b0;
            s2_busy <= 1'b0;
        end else begin
            s0_busy <= (grant == G_S0) || s0_want;
            s1_busy <= (grant == G_S1) || s1_want;
            s2_busy <= (grant == G_S2) || s2_want;
        end
    end

endmodule
