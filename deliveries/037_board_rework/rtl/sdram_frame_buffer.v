`timescale 1ns / 1ps
// ============================================================================
// sdram_frame_buffer — 基于片上SDRAM(EG_PHY_SDRAM_2M_32)的四槽常驻帧缓冲控制器
//
// 硬件规格(EG4S20片上SDRAM):
//   容量 2M×32bit(8MB); 字地址21位 = {ba[1:0], row[10:0], col[7:0]};
//   数据32位; 字节掩码dm[3:0]; 原语内部硬连线, 无需任何外部引脚约束。
//
// 对外接口保持RGB565(16位)语义, 内部完成与32位SDRAM数据总线的适配:
//   * 每个32bit字存放2个相邻像素: 偶数x -> 低16位(dm=4'b1100),
//     奇数x -> 高16位(dm=4'b0011), 用字节掩码实现半字写, 无需读-改-写
//   * 读回时按x奇偶选择对应半字
//
// 双相时钟架构:
//   clk(0°)       — 控制逻辑时钟: 帧缓冲状态机/地址映射/仲裁/写FIFO/行缓冲
//   sdram_clk(±°) — 原语专用时钟, 由外部PLL提供180°移相版本
//   控制逻辑在0°沿输出命令/地址/数据, 原语在180°沿采样, 命令相对原语
//   内部采样点获得半周期建立时间, 消除同相方案在布线后的hold违例
//   (50MHz同相实验版实测 HWNS=-0.241ns, 违例集中在原语控制端口)。
//   读数据在180°沿输出、0°沿采样, 同样各留半周期裕量。
//
// 刷新周期(按片上SDRAM真实Die EM638325规格书):
//   tREFI=15.625us (4096次/64ms, Rev.3.2 Table 16) -> @125MHz 1953拍。
//   (官方Anlogic公式 64ms/2048行=31.25us 偏保守的半分频; 本设计取
//   tREFI直接值, 过刷新生效安全无副作用, 刷新生效代价约0.5%带宽)
//
// 写握手(pixel_valid/pixel_ready):
//   上游必须在pixel_valid&&pixel_ready同时为高时才提交像素;
//   pixel_ready表示写FIFO可接收(初始化完成且未满)。该握手保证8深FIFO
//   不因高频连续写入而静默丢像素。
//
// 四槽布局(bank 交错): 槽 s 基址 = s << 19, 即槽 0~3 各占 bank 0~3。
//   单帧 FRAME_WIDTH*FRAME_HEIGHT/2 字须 ≤ 2^19(640×480 = 153600 字, 占本 bank 29.3%)。
//   连续摆放(s × 帧字数)会让四槽全挤进 bank 0, 左右半屏读与切图写都在同一 bank 内换行。
//   写地址 = {write_frame, 19'b0} + (FRAME_HEIGHT-1-y) * (FRAME_WIDTH/2) + (x>>1)
//   (行序反转: 上游 y=0(顶行)写入物理最高行, 匹配 BMP 底行优先的存储顺序)。
//   write_frame 在一次加载期间须保持; 写 FIFO 条目在入队拍锁存完整地址。
//
// 显示槽提交: active_frame 只在 vsync_pulse 拍锁存 display_frame(帧中绝不换槽 ⇒ 无撕裂);
//   active_buffer = active_frame[0], 仅为兼容保留。frame_write_done 仍在整帧落盘当拍
//   发出(语义不变), 显示哪一槽由顶层经 display_frame 决定。
//
// 显示读口(流式, 按序响应):
//   请求 {en, slot, x, y, tag} 由上游寄存器给出(本模块把它们当稳定的寄存器输出用),
//   rd_req_ready 为组合量: en=0 恒可接收(不访问 SDRAM); en=1 须该源行已在行缓存中且
//   所需字已到达。接收后固定 2 拍给出响应 {data, en, tag}(en=0 时 data=0)。
//   行缓存 2 项全相联(LRU 替换), 每项 = 一整条源行(FRAME_WIDTH/2 字)+ 标记(槽, 行):
//     * 标记必须含槽号: 图墙上半屏左右两半同一源行号读的是两个不同槽, 只比行号
//       会让右半屏命中左半屏的行缓存而串图;
//     * 未命中即把 LRU 项整行重填: 按 8 字突发顺序连续取回, 每拍一字写入该项 BRAM,
//       填充指针之前的字即可读 ⇒ 读侧随填充推进流式放行, 不等整行完成;
//     * 抽稀/放大只发生在"行缓存 → 像素"一级(BRAM 按源 x 索引), SDRAM 侧恒为连续突发;
//     * 同一时刻至多一次行填充; 每个 vsync_pulse 使两项失效(槽内容可能已被重写,
//       新一帧首行本就必然未命中, 失效不增加访问)。
//
// 仲裁优先级: 刷新(引擎内) > 行填充读 > 像素写
// ============================================================================
module sdram_frame_buffer #(
    parameter integer FRAME_WIDTH         = 1280,
    parameter integer FRAME_HEIGHT        = 720,
    parameter integer REF_INTERVAL_CYCLES = 1953   // tREFI 15.625us @125MHz (EM638325)
)(
    // 时钟复位
    input  wire        clk,             // 控制逻辑时钟(0°)
    input  wire        sdram_clk,       // SDRAM原语时钟(180°), 原语采样用
    input  wire        rst_n,           // 异步低有效
    output reg         init_done,       // SDRAM初始化完成

    // 像素流输入(RGB565, valid/ready握手)
    input  wire        pixel_valid,
    output wire        pixel_ready,     // 写FIFO可接收; 上游仅在valid&&ready时提交
    input  wire [15:0] pixel_data,
    input  wire [10:0] pixel_x,         // 0~FRAME_WIDTH-1
    input  wire [9:0]  pixel_y,         // 0~FRAME_HEIGHT-1(顺序行号, 模块内反转)
    input  wire [1:0]  write_frame,     // 写目标槽

    // 显示读口(流式)
    input  wire        rd_req_valid,
    output wire        rd_req_ready,
    input  wire        rd_req_en,       // 1 = 取缓存像素; 0 = 占位(不访问 SDRAM)
    input  wire [1:0]  rd_req_slot,
    input  wire [10:0] rd_req_x,        // 源坐标
    input  wire [9:0]  rd_req_y,
    input  wire [1:0]  rd_req_tag,      // 随路标签, 原样随响应返回
    output reg         rd_rsp_valid,
    output reg  [15:0] rd_rsp_data,
    output reg         rd_rsp_en,
    output reg  [1:0]  rd_rsp_tag,

    // 控制信号
    input  wire        vsync_pulse,      // ctrl 域帧消隐单拍脉冲(顶层 = vs_start_pulse)
    input  wire [1:0]  display_frame,    // 期望显示的槽, vsync_pulse 拍锁存
    output reg  [1:0]  active_frame,     // 实际显示槽(仅 vsync_pulse 拍变化)
    output wire        active_buffer,    // = active_frame[0]
    output reg         frame_write_done  // 整帧写入完成脉冲(语义不变: 落盘完整)
);

    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer HALF_W       = FRAME_WIDTH / 2;              // 一条源行的字数
    localparam integer N_BURST      = HALF_W / 8;                   // 一行 = N_BURST 次 8 字突发

    localparam [19:0] HALF_W20      = HALF_W[19:0];
    localparam [10:0] FW11          = FRAME_WIDTH[10:0];
    localparam [9:0]  FH10          = FRAME_HEIGHT[9:0];

    // 行缓存每项深度取 2 的幂(TD BRAM 推断要求)
    localparam integer LC_AW = (HALF_W <= 256)  ? 8  :
                               (HALF_W <= 512)  ? 9  :
                               (HALF_W <= 1024) ? 10 : 11;
    localparam [LC_AW:0] LINE_WORDS = HALF_W[LC_AW:0];
    localparam [LC_AW:0] LAST_WORD  = LINE_WORDS - 1'b1;
    localparam [7:0]     N_BURST8   = N_BURST[7:0];

    // ========================================================================
    // 引擎/定时器互连
    // ========================================================================
    wire        eng_init_done;
    wire        refresh_req, refresh_ack;
    wire        req_valid, req_ready, req_write;
    wire [20:0] req_addr;
    wire [31:0] req_wdata;
    wire [3:0]  req_dm;
    wire        resp_valid, resp_write;
    wire [31:0] resp_rdata;

    wire        beat_valid;
    wire [31:0] beat_data;
    wire [20:0] beat_addr;

    wire        eng_cke, eng_cs_n, eng_ras_n, eng_cas_n, eng_we_n, eng_dq_oe;
    wire [10:0] eng_addr;
    wire [1:0]  eng_ba;
    wire [3:0]  eng_dm;
    wire [31:0] eng_dq_out;
    wire [31:0] sdram_dq;               // 原语双向数据总线(仅内部连接)

    // [task_026 V0] 读回 DQ 的 sdram_clk(180°) 域预捕获级:
    //   原语为硬核, 其 dq 的 launch-to-valid = 时钟插入(5.832ns) + clk2q(5.0ns)
    //   + 数据 PAD(2.06ns), 在 ctrl_clk(0°) 单拍捕获下到达已越过捕获沿
    //   (实测 slack -2.25ns), 故该跳长期被 SDC 豁免 => STA 盲区, 裕量随布局漂移。
    //   改为先由 sdram_clk 捕获一级: 发射方变普通 FF(插入~2.0 + clk2q~0.4),
    //   同样 10ns 预算下 slack 转正, 盲区随之消失(该级与宏同时钟, 为同时钟域路径)。
    //   纯数据流水级, 不设复位: 读突发完成前其值恒为 don't-care,
    //   避免把 ctrl 域 rst_n 作为异步复位引入 sdram_clk 域(那会另生一次跨域)。
    reg  [31:0] dq_m;

    // 刷新定时器在初始化完成前保持复位, 初始化序列内的两次REFRESH已满足上电刷新要求
    wire timer_rst_n = rst_n & eng_init_done;

    sdram_refresh_timer #(
        .REF_INTERVAL_CYCLES (REF_INTERVAL_CYCLES)
    ) u_refresh_timer (
        .clk        (clk),
        .rst_n      (timer_rst_n),
        .refresh_req(refresh_req),
        .ref_ack    (refresh_ack)
    );

    sdram_cmd_engine u_cmd_engine (
        .clk        (clk),
        .rst_n      (rst_n),
        .init_done  (eng_init_done),
        .refresh_req(refresh_req),
        .refresh_ack(refresh_ack),
        .req_valid  (req_valid),
        .req_ready  (req_ready),
        .req_write  (req_write),
        .req_addr   (req_addr),
        .req_wdata  (req_wdata),
        .req_dm     (req_dm),
        .resp_valid (resp_valid),
        .resp_write (resp_write),
        .resp_rdata (resp_rdata),
        .beat_valid (beat_valid),
        .beat_data  (beat_data),
        .beat_addr  (beat_addr),
        .sdr_cke    (eng_cke),
        .sdr_cs_n   (eng_cs_n),
        .sdr_ras_n  (eng_ras_n),
        .sdr_cas_n  (eng_cas_n),
        .sdr_we_n   (eng_we_n),
        .sdr_addr   (eng_addr),
        .sdr_ba     (eng_ba),
        .sdr_dm     (eng_dm),
        .sdr_dq_out (eng_dq_out),
        .sdr_dq_oe  (eng_dq_oe),
        .sdr_dq_in  (dq_m)          // [V0] 经 sdram_clk 域预捕获一级
    );

    // ========================================================================
    // 片上SDRAM原语实例化(仿真时由tb目录行为模型替代, 综合时用安路器件库单元)
    //   时钟取sdram_clk(180°): 原语在反相沿采样命令与更新读数据,
    //   与控制逻辑(0°)共同构成双相时钟架构。
    // ========================================================================
    EG_PHY_SDRAM_2M_32 u_sdram (
        .clk    (sdram_clk),
        .ras_n  (eng_ras_n),
        .cas_n  (eng_cas_n),
        .we_n   (eng_we_n),
        .addr   (eng_addr),        // [10:0]
        .ba     (eng_ba),          // [1:0]
        .dq     (sdram_dq),        // [31:0] inout
        .cs_n   (eng_cs_n),
        .dm0    (eng_dm[0]),
        .dm1    (eng_dm[1]),
        .dm2    (eng_dm[2]),
        .dm3    (eng_dm[3]),
        .cke    (eng_cke)
    );

    assign sdram_dq = eng_dq_oe ? eng_dq_out : 32'bz;

    // [task_026 V0] 读回 DQ 预捕获级(见声明处注释)。
    //   与 u_sdram 同为 sdram_clk 上升沿 => 本级的 D 是原语上一拍输出的值,
    //   构成同时钟域路径(预算为完整 20ns 周期), 不再依赖 180° 异相半周期关系。
    //   副作用: 读回数据相对原语输出滞后整整一拍, 由 sdram_cmd_engine 的
    //   ST_RD_CL 等待 +1 拍补偿(见该文件 CAS_LAT-2)。
    always @(posedge sdram_clk) begin
        dq_m <= sdram_dq;
    end

    // ========================================================================
    // 写通路: 坐标->字地址, RGB565->32bit半字组装, 8深FIFO
    // ========================================================================
    wire        pix_coord_ok = (pixel_x < FW11) && (pixel_y < FH10);

    wire [20:0] wr_base   = {write_frame, 19'b0};
    wire [9:0]  wr_inv_y  = (FRAME_HEIGHT-1) - pixel_y;          // 行序反转
    wire [19:0] wr_rowoff = wr_inv_y * HALF_W20;                 // (H-1-y)*(W/2)
    wire [20:0] wr_waddr  = wr_base + {1'b0, wr_rowoff} + {11'b0, pixel_x[10:1]};

    wire [31:0] wr_wdata = pixel_x[0] ? {pixel_data, 16'd0}    // 奇数x: 高半字
                                      : {16'd0, pixel_data};   // 偶数x: 低半字
    wire [3:0]  wr_dm    = pixel_x[0] ? 4'b0011 : 4'b1100;

    localparam WF_AW = 3;                       // FIFO深度8
    reg  [56:0] wf_mem [0:(1<<WF_AW)-1];        // {dm[3:0], data[31:0], addr[20:0]}
    reg  [WF_AW:0] wf_wr_ptr, wf_rd_ptr;

    wire wf_full  = (wf_wr_ptr[WF_AW] != wf_rd_ptr[WF_AW]) &&
                    (wf_wr_ptr[WF_AW-1:0] == wf_rd_ptr[WF_AW-1:0]);
    wire wf_empty = (wf_wr_ptr == wf_rd_ptr);

    // pixel_ready: 初始化完成且FIFO未满(坐标越界的像素由pix_coord_ok拒绝,
    // 不占用FIFO; 上游在valid&&ready握手下每个合法像素恰好入队一次)。
    assign pixel_ready = eng_init_done && !wf_full;
    wire wf_push  = pixel_valid && pixel_ready && pix_coord_ok;

    // ========================================================================
    // 读通路: 2 项整行缓存
    // ========================================================================
    reg  [1:0]       lc_valid;
    reg  [1:0]       lc_slot0, lc_slot1;
    reg  [9:0]       lc_line0, lc_line1;
    reg  [LC_AW:0]   lc_fill0, lc_fill1;        // 已到达字数(0..HALF_W), 按序填充
    reg              lc_lru;                    // 下一次替换的项

    reg              fill_active;
    reg              fill_way;
    reg  [20:0]      fill_addr;                 // 下一次突发的字地址
    reg  [7:0]       fill_bcnt;                 // 已发出突发数
    reg  [LC_AW:0]   fill_wcnt;                 // 已写入字数
    reg              inval_pend;

    wire [LC_AW-1:0] rq_word = rd_req_x[LC_AW:1];

    wire hit0   = lc_valid[0] && (lc_slot0 == rd_req_slot) && (lc_line0 == rd_req_y);
    wire hit1   = lc_valid[1] && (lc_slot1 == rd_req_slot) && (lc_line1 == rd_req_y);
    wire avail0 = hit0 && ({1'b0, rq_word} < lc_fill0);
    wire avail1 = hit1 && ({1'b0, rq_word} < lc_fill1);

    assign rd_req_ready = eng_init_done && (!rd_req_en || avail0 || avail1);
    wire   rd_acc       = rd_req_valid && rd_req_ready;

    // 失效在无填充时立即生效, 填充中则延到填充完成
    wire   do_inval = (vsync_pulse || inval_pend) && !fill_active;
    wire   rd_miss  = rd_req_valid && rd_req_en && !hit0 && !hit1;
    wire   do_alloc = rd_miss && eng_init_done && !fill_active &&
                      !vsync_pulse && !inval_pend;

    // 该源行在所属槽内的首字地址(分配拍计算并寄存)
    wire [9:0]  al_inv_y  = (FRAME_HEIGHT-1) - rd_req_y;
    wire [19:0] al_rowoff = al_inv_y * HALF_W20;
    wire [20:0] al_base   = {rd_req_slot, 19'b0} + {1'b0, al_rowoff};

    // ========================================================================
    // 仲裁: 行填充读 > 像素写 (刷新优先级在引擎内部, 高于两者)
    // ========================================================================
    wire use_rd = fill_active && (fill_bcnt < N_BURST8);
    wire use_wr = !wf_empty && !use_rd;

    assign req_valid = eng_init_done && (use_rd || use_wr);
    assign req_write = use_wr;
    assign req_addr  = use_rd ? fill_addr : wf_mem[wf_rd_ptr[WF_AW-1:0]][20:0];
    assign req_wdata = wf_mem[wf_rd_ptr[WF_AW-1:0]][52:21];
    assign req_dm    = wf_mem[wf_rd_ptr[WF_AW-1:0]][56:53];

    wire fire    = req_valid && req_ready;
    wire wf_pop  = fire && use_wr;
    wire rd_fire = fire && use_rd;

    // ========================================================================
    // 行缓存存储体(每项一个阵列: 单写口 + 寄存读出)
    // ========================================================================
    reg [31:0] lc_mem0 [0:(1<<LC_AW)-1];
    reg [31:0] lc_mem1 [0:(1<<LC_AW)-1];
    reg [31:0] lc_q0, lc_q1;

    wire lc_we0 = beat_valid && fill_active && (fill_way == 1'b0);
    wire lc_we1 = beat_valid && fill_active && (fill_way == 1'b1);

    always @(posedge clk) begin
        if (lc_we0)
            lc_mem0[fill_wcnt[LC_AW-1:0]] <= beat_data;
    end
    always @(posedge clk) begin
        if (lc_we1)
            lc_mem1[fill_wcnt[LC_AW-1:0]] <= beat_data;
    end
    always @(posedge clk) begin
        lc_q0 <= lc_mem0[rq_word];
    end
    always @(posedge clk) begin
        lc_q1 <= lc_mem1[rq_word];
    end

    // ========================================================================
    // 行缓存标记/填充控制 + 写FIFO(单一always块, 避免同一寄存器多驱动)
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wf_wr_ptr   <= {(WF_AW+1){1'b0}};
            wf_rd_ptr   <= {(WF_AW+1){1'b0}};
            lc_valid    <= 2'b00;
            lc_slot0    <= 2'd0;
            lc_slot1    <= 2'd0;
            lc_line0    <= 10'd0;
            lc_line1    <= 10'd0;
            lc_fill0    <= {(LC_AW+1){1'b0}};
            lc_fill1    <= {(LC_AW+1){1'b0}};
            lc_lru      <= 1'b0;
            fill_active <= 1'b0;
            fill_way    <= 1'b0;
            fill_addr   <= 21'd0;
            fill_bcnt   <= 8'd0;
            fill_wcnt   <= {(LC_AW+1){1'b0}};
            inval_pend  <= 1'b0;
        end else begin
            // ---- 写FIFO ----
            if (wf_push) begin
                wf_mem[wf_wr_ptr[WF_AW-1:0]] <= {wr_dm, wr_wdata, wr_waddr};
                wf_wr_ptr <= wf_wr_ptr + 1'b1;
            end
            if (wf_pop)
                wf_rd_ptr <= wf_rd_ptr + 1'b1;

            // ---- 突发发出 ----
            if (rd_fire) begin
                fill_addr <= fill_addr + 21'd8;
                fill_bcnt <= fill_bcnt + 8'd1;
            end

            // ---- 突发拍写入 -> 填充指针推进 ----
            if (beat_valid && fill_active) begin
                fill_wcnt <= fill_wcnt + 1'b1;
                if (fill_way) lc_fill1 <= fill_wcnt + 1'b1;
                else          lc_fill0 <= fill_wcnt + 1'b1;
                if (fill_wcnt == LAST_WORD)
                    fill_active <= 1'b0;
            end

            // ---- LRU: 被接收的取像素请求所在项成为最近使用 ----
            if (rd_acc && rd_req_en)
                lc_lru <= !avail1;

            // ---- 失效 / 分配 ----
            if (do_inval) begin
                lc_valid   <= 2'b00;
                inval_pend <= 1'b0;
            end else if (vsync_pulse) begin
                inval_pend <= 1'b1;
            end

            if (do_alloc) begin
                fill_active <= 1'b1;
                fill_way    <= lc_lru;
                fill_addr   <= al_base;
                fill_bcnt   <= 8'd0;
                fill_wcnt   <= {(LC_AW+1){1'b0}};
                lc_lru      <= !lc_lru;
                if (lc_lru) begin
                    lc_valid[1] <= 1'b1;
                    lc_slot1    <= rd_req_slot;
                    lc_line1    <= rd_req_y;
                    lc_fill1    <= {(LC_AW+1){1'b0}};
                end else begin
                    lc_valid[0] <= 1'b1;
                    lc_slot0    <= rd_req_slot;
                    lc_line0    <= rd_req_y;
                    lc_fill0    <= {(LC_AW+1){1'b0}};
                end
            end
        end
    end

    // ========================================================================
    // 读响应: 接收后第 2 拍输出(第 1 拍为存储体寄存读出)
    // ========================================================================
    reg        p1_v, p1_en, p1_way, p1_half;
    reg [1:0]  p1_tag;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_v         <= 1'b0;
            p1_en        <= 1'b0;
            p1_way       <= 1'b0;
            p1_half      <= 1'b0;
            p1_tag       <= 2'd0;
            rd_rsp_valid <= 1'b0;
            rd_rsp_en    <= 1'b0;
            rd_rsp_tag   <= 2'd0;
            rd_rsp_data  <= 16'd0;
        end else begin
            p1_v    <= rd_acc;
            p1_en   <= rd_req_en;
            p1_way  <= avail1;
            p1_half <= rd_req_x[0];
            p1_tag  <= rd_req_tag;

            rd_rsp_valid <= p1_v;
            rd_rsp_en    <= p1_v && p1_en;
            rd_rsp_tag   <= p1_tag;
            if (p1_v && p1_en)
                rd_rsp_data <= p1_way ? (p1_half ? lc_q1[31:16] : lc_q1[15:0])
                                      : (p1_half ? lc_q0[31:16] : lc_q0[15:0]);
            else
                rd_rsp_data <= 16'd0;
        end
    end

    // ========================================================================
    // 帧完成计数(统计已落盘的写事务) + 显示槽提交
    // ========================================================================
    reg [19:0] frame_px_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_px_cnt     <= 20'd0;
            frame_write_done <= 1'b0;
        end else begin
            frame_write_done <= 1'b0;
            if (resp_valid && resp_write) begin
                if (frame_px_cnt == FRAME_PIXELS-1) begin
                    frame_px_cnt     <= 20'd0;
                    frame_write_done <= 1'b1;
                end else begin
                    frame_px_cnt <= frame_px_cnt + 20'd1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            active_frame <= 2'd0;
        else if (vsync_pulse)
            active_frame <= display_frame;
    end
    assign active_buffer = active_frame[0];

    // ========================================================================
    // init_done输出寄存
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) init_done <= 1'b0;
        else        init_done <= eng_init_done;
    end

    // ========================================================================
    // 调试计数器(仅供仿真层级观测, 不引出端口)
    // ========================================================================
    reg [15:0] dbg_wr_drop_cnt;     // 握手期pixel_valid&&!pixel_ready等待拍数(背压统计)
    reg [15:0] dbg_wr_accept_cnt;   // 握手成功接受的像素总数(丢像素的客观判据)
    reg [15:0] dbg_pix_ignored_cnt; // 坐标越界被忽略的像素
    reg [15:0] dbg_rd_resp_cnt;     // 已产生的读响应数
    reg [15:0] dbg_fill_cnt;        // 行填充次数
    reg [15:0] dbg_rd_pad_cnt;      // en=0 请求数(不访问 SDRAM)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_wr_drop_cnt    <= 16'd0;
            dbg_wr_accept_cnt  <= 16'd0;
            dbg_pix_ignored_cnt<= 16'd0;
            dbg_rd_resp_cnt    <= 16'd0;
            dbg_fill_cnt       <= 16'd0;
            dbg_rd_pad_cnt     <= 16'd0;
        end else begin
            if (pixel_valid && pixel_ready && pix_coord_ok)
                dbg_wr_accept_cnt <= dbg_wr_accept_cnt + 16'd1;
            if (pixel_valid && !pixel_ready && eng_init_done)
                dbg_wr_drop_cnt <= dbg_wr_drop_cnt + 16'd1;
            if (pixel_valid && pixel_ready && !pix_coord_ok)
                dbg_pix_ignored_cnt <= dbg_pix_ignored_cnt + 16'd1;
            if (rd_rsp_valid)
                dbg_rd_resp_cnt <= dbg_rd_resp_cnt + 16'd1;
            if (do_alloc)
                dbg_fill_cnt <= dbg_fill_cnt + 16'd1;
            if (rd_acc && !rd_req_en)
                dbg_rd_pad_cnt <= dbg_rd_pad_cnt + 16'd1;
        end
    end

    wire _unused = &{1'b0, resp_rdata, beat_addr, 1'b0};

endmodule
