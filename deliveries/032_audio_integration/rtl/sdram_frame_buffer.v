`timescale 1ns / 1ps
// ============================================================================
// sdram_frame_buffer — 基于片上SDRAM(EG_PHY_SDRAM_2M_32)的双缓冲帧缓冲控制器
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
// 地址映射(字地址, 21位):
//   waddr = buffer_base + (FRAME_HEIGHT-1-y) * (FRAME_WIDTH/2) + (x>>1)
//   行序反转: 上游像素流y=0(顶行)写入物理最高行, 匹配BMP底行优先存储顺序
//
// 双缓冲([task_026 第三步] VSYNC 帧边界提交):
//   active_buffer = 显示读缓冲(前台): 0=Buffer A(base 0), 1=Buffer B(base 460800字)
//   写通路始终写入后台缓冲(~active_buffer);
//   整帧(FRAME_WIDTH*FRAME_HEIGHT个像素)全部落盘后产生frame_write_done脉冲
//   (语义不变: "整帧数据已完整落盘", loader 提交判定/FE 武装时序与旧版逐拍
//   一致), 但 active_buffer 不再同拍翻转, 而是置 pending_commit, 等到
//   vsync_pulse(ctrl 域帧消隐单拍脉冲, 顶层接 VS 下降沿 CDC 链的
//   vs_start_pulse)才翻转 —— 显示读侧旧→新切换只发生在消隐窗口, 消除
//   任意时刻翻转造成的帧内撕裂。翻转拍与 FE 触发拍为同一 vsync_pulse:
//   FE 首个 display_req 在脉冲后 1 拍发出, 彼时 active_buffer 已更新,
//   首帧即读新缓冲(无"多显示一帧旧内容"延迟)。在途读事务/行缓冲/请求
//   队列均带 tag(=发起拍 active_buffer), 翻转后旧 tag 条目正常响应、
//   不与新请求合并, 数据归属正确。
//   病态快写边界(登记): 若 pending_commit 未决期间又写满一整帧(需 <1 个
//   场消隐周期写完两帧, 真实 SD 加载链路为秒级, 不可达), 后帧覆盖同一
//   后台缓冲, 消隐翻转后显示最新完整帧, 前帧被跳过, 无撕裂/无残留混帧。
//
// 读通路突发优化(BL=8):
//   读请求按8字块(=16像素)对齐; 一次READ事务取回整块8个字并全部存入行缓冲,
//   后续落在同一块内的请求由行缓冲命中返回(2拍), 不再访问SDRAM。
//   吞吐: 16像素 / ~20拍 @125MHz ≈ 0.8 像素/拍 ≈ 100 Mpixel/s,
//   满足720p60(像素时钟74.25MHz); 上游需带≥1块(16像素)预读提前量,
//   以吸收首次未命中的事务延迟(见 doc/spec/behavior_spec.md)。
//
// 仲裁优先级: 刷新(引擎内) > 显示读 > 像素写
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
    input  wire [10:0] pixel_x,         // 0~1279
    input  wire [9:0]  pixel_y,         // 0~719(顺序行号, 模块内反转)

    // 显示控制器读取接口
    input  wire        display_req,
    input  wire [10:0] display_x,
    input  wire [9:0]  display_y,
    output reg  [15:0] display_data,
    output reg         display_valid,

    // 控制信号
    input  wire        vsync_pulse,      // [task_026 第三步] ctrl 域帧消隐单拍
                                         // 脉冲(顶层=vs_start_pulse, VS 下降沿
                                         // 经 2FF CDC); 帧提交翻转唯一窗口
    output reg         frame_write_done, // 整帧写入完成脉冲(语义不变: 落盘完整)
    output reg         active_buffer     // 显示读缓冲: 0=A, 1=B(vsync 消隐期翻转)
);

    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;   // 921600
    localparam integer FRAME_WORDS  = FRAME_PIXELS / 2;             // 460800
    localparam integer HALF_W       = FRAME_WIDTH / 2;              // 640

    localparam [20:0] FRAME_WORDS21 = FRAME_WORDS[20:0];
    localparam [19:0] HALF_W20      = HALF_W[19:0];
    localparam [10:0] FW11          = FRAME_WIDTH[10:0];
    localparam [9:0]  FH10          = FRAME_HEIGHT[9:0];

    localparam [20:0] BASE_A = 21'h00_0000;                 // 0
    localparam [20:0] BASE_B = BASE_A + FRAME_WORDS21;      // 460800 = 0x070800

    localparam integer BURST_WORDS = 8;                     // 一次突发取回的字数

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

    // 写基地址 = 后台缓冲: active_buffer=0(显示A) -> 写B; active_buffer=1(显示B) -> 写A
    wire [20:0] wr_base   = active_buffer ? BASE_A : BASE_B;
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
    // 读通路: 坐标->字地址, 8字块请求队列(带位图合并) + 行缓冲
    // ========================================================================
    // 读基地址 = 前台缓冲(active_buffer)
    wire [20:0] rd_base   = active_buffer ? BASE_B : BASE_A;
    wire [9:0]  rd_inv_y  = (FRAME_HEIGHT-1) - display_y;
    wire [19:0] rd_rowoff = rd_inv_y * HALF_W20;
    wire [20:0] rd_waddr  = rd_base + {1'b0, rd_rowoff} + {11'b0, display_x[10:1]};

    wire [17:0] rd_blk  = rd_waddr[20:3];       // 8字块号
    wire [2:0]  rd_idx  = rd_waddr[2:0];        // 块内字序号
    wire        rd_half = display_x[0];         // 0=低半字, 1=高半字
    wire [7:0]  rd_bit  = 8'd1 << rd_idx;

    // ---- 行缓冲: 最近一次突发取回的8个字 ----
    reg         lb_tag;                         // 数据所属显示缓冲
    reg  [17:0] lb_blk;
    reg  [7:0]  lb_vld;                         // 逐字有效位图
    reg  [31:0] lb_data [0:BURST_WORDS-1];

    wire lb_hit = lb_vld[rd_idx] && (lb_blk == rd_blk) && (lb_tag == active_buffer);

    // ---- 在途事务 ----
    reg         if_active;
    reg         if_tag;
    reg  [17:0] if_blk;
    reg  [7:0]  if_req;                         // 块内待响应字位图
    reg  [7:0]  if_half;                        // 对应半字选择
    reg  [3:0]  if_beats;                       // 已发出的突发拍数

    // 尚未发出的拍才可追加请求(本拍正在响应的字无法再插入)
    wire [3:0]  next_beat = if_beats + (beat_valid ? 4'd1 : 4'd0);
    wire        if_catch  = if_active && (if_blk == rd_blk) &&
                            (if_tag == active_buffer) &&
                            ({1'b0, rd_idx} >= next_beat);

    // ---- 块请求队列(深度2, 同块请求按位图合并) ----
    // 条目: {tag(1), blk(18), req(8), half(8)} = 35位
    reg  [34:0] rq_mem [0:1];
    reg  [1:0]  rq_wr_ptr, rq_rd_ptr;
    wire        rq_full  = (rq_wr_ptr[1] != rq_rd_ptr[1]) &&
                           (rq_wr_ptr[0] == rq_rd_ptr[0]);
    wire        rq_empty = (rq_wr_ptr == rq_rd_ptr);
    wire        rq_tail  = rq_wr_ptr[0] - 1'b1;
    wire        rq_head  = rq_rd_ptr[0];
    wire        rq_tail_match = !rq_empty &&
                                (rq_mem[rq_tail][34]    == active_buffer) &&
                                (rq_mem[rq_tail][33:16] == rd_blk);

    // ========================================================================
    // 仲裁: 显示读 > 像素写 (刷新优先级在引擎内部, 高于两者)
    // ========================================================================
    wire use_rd = !rq_empty;
    wire use_wr = !wf_empty && rq_empty;

    assign req_valid = eng_init_done && (use_rd || use_wr);
    assign req_write = use_wr;
    assign req_addr  = use_rd ? {rq_mem[rq_head][33:16], 3'b000}
                              : wf_mem[wf_rd_ptr[WF_AW-1:0]][20:0];
    assign req_wdata = wf_mem[wf_rd_ptr[WF_AW-1:0]][52:21];
    assign req_dm    = wf_mem[wf_rd_ptr[WF_AW-1:0]][56:53];

    wire fire   = req_valid && req_ready;
    wire wf_pop = fire && use_wr;
    wire rq_pop = fire && use_rd;

    // ========================================================================
    // 读通路+写FIFO 状态(单一always块, 避免同一寄存器多驱动)
    // ========================================================================
    integer i_lb;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wf_wr_ptr <= {(WF_AW+1){1'b0}};
            wf_rd_ptr <= {(WF_AW+1){1'b0}};
            rq_wr_ptr <= 2'b00;
            rq_rd_ptr <= 2'b00;
            if_active <= 1'b0;
            if_tag    <= 1'b0;
            if_blk    <= 18'd0;
            if_req    <= 8'd0;
            if_half   <= 8'd0;
            if_beats  <= 4'd0;
            lb_tag    <= 1'b0;
            lb_blk    <= 18'd0;
            lb_vld    <= 8'd0;
            for (i_lb = 0; i_lb < BURST_WORDS; i_lb = i_lb + 1)
                lb_data[i_lb] <= 32'd0;
        end else begin
            // ---- 突发拍捕获 -> 行缓冲 ----
            if (beat_valid) begin
                lb_data[beat_addr[2:0]] <= beat_data;
                lb_vld[beat_addr[2:0]]  <= 1'b1;
                lb_blk                  <= beat_addr[20:3];
                lb_tag                  <= if_tag;
                if_beats                <= if_beats + 4'd1;
            end

            // ---- 读事务结束(resp_valid在ST_DONE发出, 与新事务派发可同拍, 派发在后覆盖) ----
            if (resp_valid && !resp_write)
                if_active <= 1'b0;

            // ---- 写FIFO ----
            if (wf_push) begin
                wf_mem[wf_wr_ptr[WF_AW-1:0]] <= {wr_dm, wr_wdata, wr_waddr};
                wf_wr_ptr <= wf_wr_ptr + 1'b1;
            end
            if (wf_pop)
                wf_rd_ptr <= wf_rd_ptr + 1'b1;

            // ---- 新读请求: 行缓冲未命中且无法搭在途突发 -> 入队/同块合并 ----
            if (display_req && eng_init_done && !lb_hit && !if_catch) begin
                if (rq_tail_match) begin
                    rq_mem[rq_tail][15:8] <= rq_mem[rq_tail][15:8] | rd_bit;
                    rq_mem[rq_tail][7:0]  <= rd_half ? (rq_mem[rq_tail][7:0] | rd_bit)
                                                     : (rq_mem[rq_tail][7:0] & ~rd_bit);
                end else if (!rq_full) begin
                    rq_mem[rq_wr_ptr[0]] <= {active_buffer, rd_blk, rd_bit,
                                             rd_half ? rd_bit : 8'd0};
                    rq_wr_ptr <= rq_wr_ptr + 2'b01;
                end
            end

            // ---- 在途同块追加(该字所在突发拍尚未发出) ----
            if (display_req && eng_init_done && !lb_hit && if_catch) begin
                if_req[rd_idx]  <= 1'b1;
                if_half[rd_idx] <= rd_half;
            end

            // ---- 队首派发到引擎 ----
            if (rq_pop) begin
                if_active <= 1'b1;
                if_tag    <= rq_mem[rq_head][34];
                if_blk    <= rq_mem[rq_head][33:16];
                if_req    <= rq_mem[rq_head][15:8];
                if_half   <= rq_mem[rq_head][7:0];
                if_beats  <= 4'd0;
                rq_rd_ptr <= rq_rd_ptr + 2'b01;
                // 换块: 行缓冲旧内容失效
                lb_vld    <= 8'd00;
                lb_blk    <= rq_mem[rq_head][33:16];
                lb_tag    <= rq_mem[rq_head][34];
            end
        end
    end

    // ========================================================================
    // 读响应输出: 在途突发拍优先, 其次行缓冲命中(2拍延迟)
    // ========================================================================
    reg         hit_pend;
    reg  [15:0] hit_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hit_pend <= 1'b0;
            hit_data <= 16'd0;
        end else begin
            hit_pend <= display_req && eng_init_done && lb_hit;
            hit_data <= rd_half ? lb_data[rd_idx][31:16] : lb_data[rd_idx][15:0];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            display_data  <= 16'd0;
            display_valid <= 1'b0;
        end else begin
            display_valid <= 1'b0;
            if (beat_valid && if_active && if_req[beat_addr[2:0]]) begin
                display_data  <= if_half[beat_addr[2:0]] ? beat_data[31:16]
                                                         : beat_data[15:0];
                display_valid <= 1'b1;
            end else if (hit_pend) begin
                display_data  <= hit_data;
                display_valid <= 1'b1;
            end
        end
    end

    // ========================================================================
    // 帧完成计数与双缓冲切换(统计已落盘的写事务, 保证整帧数据完整后才切换)
    // [task_026 第三步] VSYNC 帧边界提交:
    //   frame_write_done 仍在整帧落盘当拍发出(loader/FE 消费时序与旧版逐拍
    //   一致); active_buffer 翻转改为等待 vsync_pulse 消隐窗口:
    //     * 完成拍恰逢 vsync_pulse -> 当拍即翻(消隐窗口内, 合法);
    //     * 否则置 pending_commit, 到下一个 vsync_pulse 拍翻转。
    // ========================================================================
    reg [19:0] frame_px_cnt;
    reg        pending_commit;      // 整帧已落盘, 等待消隐窗口翻转

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_px_cnt     <= 20'd0;
            frame_write_done <= 1'b0;
            active_buffer    <= 1'b0;
            pending_commit   <= 1'b0;
        end else begin
            frame_write_done <= 1'b0;
            if (resp_valid && resp_write) begin
                if (frame_px_cnt == FRAME_PIXELS-1) begin
                    frame_px_cnt     <= 20'd0;
                    frame_write_done <= 1'b1;
                    if (vsync_pulse) begin
                        // 完成拍即消隐窗口: 当拍翻转(等价 pending 立即清偿)
                        active_buffer  <= ~active_buffer;
                        pending_commit <= 1'b0;
                    end else begin
                        pending_commit <= 1'b1;
                    end
                end else begin
                    frame_px_cnt <= frame_px_cnt + 20'd1;
                end
            end else if (pending_commit && vsync_pulse) begin
                active_buffer  <= ~active_buffer;
                pending_commit <= 1'b0;
            end
        end
    end

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
    reg [15:0] dbg_rd_drop_cnt;     // 读队列满导致的请求丢弃
    reg [15:0] dbg_pix_ignored_cnt; // 坐标越界被忽略的像素
    reg [15:0] dbg_rd_resp_cnt;     // 已产生的读响应数
    reg [15:0] dbg_rd_hit_cnt;      // 行缓冲命中次数

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_wr_drop_cnt    <= 16'd0;
            dbg_wr_accept_cnt  <= 16'd0;
            dbg_rd_drop_cnt    <= 16'd0;
            dbg_pix_ignored_cnt<= 16'd0;
            dbg_rd_resp_cnt    <= 16'd0;
            dbg_rd_hit_cnt     <= 16'd0;
        end else begin
            if (pixel_valid && pixel_ready && pix_coord_ok)
                dbg_wr_accept_cnt <= dbg_wr_accept_cnt + 16'd1;
            if (pixel_valid && !pixel_ready && eng_init_done)
                dbg_wr_drop_cnt <= dbg_wr_drop_cnt + 16'd1;
            if (pixel_valid && pixel_ready && !pix_coord_ok)
                dbg_pix_ignored_cnt <= dbg_pix_ignored_cnt + 16'd1;
            if (display_req && eng_init_done && !lb_hit && !if_catch &&
                !rq_tail_match && rq_full)
                dbg_rd_drop_cnt <= dbg_rd_drop_cnt + 16'd1;
            if (display_req && eng_init_done && lb_hit)
                dbg_rd_hit_cnt <= dbg_rd_hit_cnt + 16'd1;
            if (display_valid)
                dbg_rd_resp_cnt <= dbg_rd_resp_cnt + 16'd1;
        end
    end

endmodule