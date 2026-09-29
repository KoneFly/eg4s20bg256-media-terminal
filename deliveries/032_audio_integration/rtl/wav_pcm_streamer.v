`timescale 1ns/1ps

// WAV 流式播放器：TF 卡扇区字节流 → 48kHz PCM 样本流。
//
// TF 卡读取（~1.2MB/s 突发）与音频消费（96KB/s @48kHz 16bit mono）速率差约
// 12.5:1，中间用 4096×16 reg 数组循环缓冲吸收抖动（不依赖外部 IP）。
//
// 写侧（wr_clk，SD SPI 引擎域）：扇区级状态机——请求一扇区、收 512 字节、
//   小端拼成 256 个 16bit 样本写 BRAM、再请求下一扇区。
// 读侧（rd_clk，音频链域）：sample_tick 脉冲消费一个样本；先预填充一个扇区
//   （256 样本）再开播；播完（stream_end）后排空残余样本，残余播空后
//   sample_valid 熄灭——与中途下溢（valid 保持、输出 0）严格区分。
//
// 水位流控（写侧，迟滞）：剩余空间不足一扇区时暂停请求；水位降到 25% 以下
//   恢复请求。跨域指针用源域寄存格雷码 + 目的域 2FF 同步；两域复位均为
//   异步置位 / 同步释放（每域一个复位桥）。
//
// 数据格式约定：TF 卡存原始 16bit 有符号小端 PCM、48kHz 单声道（PC 工具
// 预处理写入），FPGA 不做 WAV 头解析，start_lba 指向数据首扇区。
module wav_pcm_streamer #(
    parameter integer ADDR_WIDTH = 12,         // 4096 x 16-bit = 8 KB
    parameter integer SAMPLES_PER_SECTOR = 256 // 512 bytes / 2
) (
    // 写侧：SD SPI 引擎时钟域
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        play_enable,        // 电平有效：流式播放中
    input  wire [31:0] start_lba,          // 数据首扇区（WAV 头之后）
    input  wire [31:0] total_sectors,      // 音频数据总扇区数
    output wire        sd_req,             // 请求一扇区读
    output reg  [31:0] sd_lba,
    input  wire        sd_busy,
    input  wire        sd_valid,           // 每 valid 一拍一字节（LSB 先）
    input  wire [7:0]  sd_byte,
    input  wire [8:0]  sd_byte_index,      // 0..511 扇区内字节序（调试观测用）
    input  wire        sd_done,
    input  wire [7:0]  sd_error,

    // 读侧：音频链时钟域
    input  wire        rd_clk,
    input  wire        rd_rst_n,
    input  wire        sample_tick,        // ~48kHz 脉冲：消费一个样本
    output reg  signed [15:0] sample_out,
    output reg         sample_valid,
    input  wire        sample_ready,       // 下游反压（本链恒 1）

    // 状态（读侧观测）
    output reg  [31:0] sample_counter,     // 已消费样本数
    output wire        stream_active,      // 播放中
    output wire        stream_end,         // 全部扇区读完
    output wire        buffer_low          // 读侧水位 < 25%
);
    localparam integer CAP = (1 << ADDR_WIDTH);

    // ---------------- 复位桥：异步置位 / 同步释放（每域一个） ----------------
    reg wr_rs1, wr_rs2;
    reg rd_rs1, rd_rs2;
    reg drain_done_r;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin wr_rs1 <= 1'b0; wr_rs2 <= 1'b0; end
        else           begin wr_rs1 <= 1'b1; wr_rs2 <= wr_rs1; end
    end
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin rd_rs1 <= 1'b0; rd_rs2 <= 1'b0; end
        else           begin rd_rs1 <= 1'b1; rd_rs2 <= rd_rs1; end
    end
    wire wr_sync_rst_n = wr_rs2;
    wire rd_sync_rst_n = rd_rs2;

    // ---------------- 循环缓冲与指针 ----------------
    reg [15:0] buffer [0:CAP-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;    // 写指针（wr_clk 域）
    reg [ADDR_WIDTH-1:0] rd_ptr;    // 读指针（rd_clk 域）

    // 缓冲写口独立成无复位进程：BRAM 写口无复位端，写语句若留在带复位的
    // FSM 进程内会破坏 TD 的 BRAM 模板匹配，退化为分布式 LUT RAM
    // （4096x16 退化实测 +6k LUT 且 hold 违例）。与 async_pixel_fifo 同构。
    wire wr_fire = (wstate == WS_FILL) && sd_valid && lo_pending;
    always @(posedge wr_clk) begin
        if (wr_fire)
            buffer[wr_ptr] <= {sd_byte, lo_byte};  // 高字节后到，拼 16bit
    end

    // 格雷码：源域寄存，目的域 2FF 采样（相邻值只差 1 位，采样亚稳最多差 1）
    reg [ADDR_WIDTH-1:0] wr_gray;                        // wr 域寄存
    reg [ADDR_WIDTH-1:0] wr_gray_sync1, wr_gray_sync2;   // rd 域 2FF
    reg [ADDR_WIDTH-1:0] rd_gray;                        // rd 域寄存
    reg [ADDR_WIDTH-1:0] rd_gray_sync1, rd_gray_sync2;   // wr 域 2FF

    function [ADDR_WIDTH-1:0] to_gray;
        input [ADDR_WIDTH-1:0] b;
        begin
            to_gray = b ^ (b >> 1);
        end
    endfunction

    function [ADDR_WIDTH-1:0] from_gray;
        input [ADDR_WIDTH-1:0] g;
        reg [ADDR_WIDTH-1:0] b;
        integer i;
        begin
            b[ADDR_WIDTH-1] = g[ADDR_WIDTH-1];
            for (i = ADDR_WIDTH-2; i >= 0; i = i - 1)
                b[i] = b[i+1] ^ g[i];
            from_gray = b;
        end
    endfunction

    // 对方域看到的指针（滞后若干拍，水位估计偏保守：写侧高估、读侧低估）
    wire [ADDR_WIDTH-1:0] wr_ptr_in_rd = from_gray(wr_gray_sync2);
    wire [ADDR_WIDTH-1:0] rd_ptr_in_wr = from_gray(rd_gray_sync2);

    // 水位：写域用于流控，读域用于预填充/下溢/buffer_low
    //   **12bit 模减即为真水位**：设计不变量是水位上限 4095(= CAP-1，见下方
    //   迟滞注释)，故模 4096 相减无满/空歧义，无需扩展位。
    //   旧写法把两指针零扩展到 13bit 再相减，在 wr_ptr 数值小于 rd_ptr 的
    //   **指针回绕区**得到 真水位+4096 ⇒ lvl_set(>3839) 恒真、lvl_clr(<1024)
    //   恒假 ⇒ 写侧在整个回绕区被误判"快满"而停止请求，缓冲被读空到 wr_ptr+1
    //   才恢复；wr_ptr 恰为小值(刚回绕)时即欠载出静音。单独播放时补扇区及时、
    //   听感无损；切图期 SD 被显示加载占用，补一扇区要等一个事务边界(数百 us)，
    //   欠载被放大成可闻断音 —— tb_wps_unit W3(与争用无关) / tb_p1x X6+X7
    //   (切图期 716 个样本错、最长 36 拍静音)即此根因。
    wire [ADDR_WIDTH-1:0] level_wr = wr_ptr - rd_ptr_in_wr;
    wire [ADDR_WIDTH-1:0] level_rd = wr_ptr_in_rd - rd_ptr;

    // ---------------- 写侧状态机 ----------------
    localparam [2:0] WS_IDLE = 3'd0;
    localparam [2:0] WS_REQ  = 3'd1;
    localparam [2:0] WS_FILL = 3'd2;
    localparam [2:0] WS_END  = 3'd4;
    reg [2:0]  wstate;
    reg [31:0] cur_lba;
    reg [31:0] sectors_read;
    reg [7:0]  lo_byte;             // 小端字节对组装：先收低字节
    reg        lo_pending;
    reg        wr_hold;             // 水位流控：1=暂停请求

    // ended 标志（1bit）跨域到读侧：替代多位状态码直采，避免撕裂采样
    wire ended_w = (wstate == WS_END);
    reg  ended_sync1, ended_sync2;

    assign sd_req        = (wstate == WS_REQ) && !wr_pause;
    // stream_active 覆盖排空期: 读尽(WS_END)后只要读侧仍有残余样本就保持高,
    // 顶层 wav_active 据此不在排空前提前切源(截断/爆音); 残余耗尽才回落。
    // drain_done 寄存一拍: 末次 drain take 拍 level 即归零, 而末样本 valid 还
    // 要再经一级流水才出现; 不寄存则 stream_active 早末 valid 一拍落下, 尾拍被切。
    assign stream_active = play_enable && !drain_done_r;
    assign stream_end    = (wstate == WS_END);
    assign buffer_low    = (level_rd < (CAP >> 2));    // < 25%

    // 水位迟滞：剩余空间不足一扇区（level > CAP-256-1）置停；
    // 水位降到 25%（1024）以下恢复。指针 12bit 无扩展位，水位上限取 4095，
    // 留 1 格余量避免满/空歧义。置停条件组合直通（lvl_set 立即生效），
    // 避免"最后一扇区写满当拍、寄存 hold 晚一拍"导致多发一次请求越过满界。
    wire lvl_set = (level_wr > (CAP - SAMPLES_PER_SECTOR - 1));
    wire lvl_clr = (level_wr < (CAP >> 2));
    always @(posedge wr_clk or negedge wr_sync_rst_n) begin
        if (!wr_sync_rst_n)
            wr_hold <= 1'b0;
        else if (lvl_clr)
            wr_hold <= 1'b0;
        else if (lvl_set)
            wr_hold <= 1'b1;
    end
    wire wr_pause = lvl_set || (wr_hold && !lvl_clr);

    always @(posedge wr_clk or negedge wr_sync_rst_n) begin
        if (!wr_sync_rst_n) begin
            wstate        <= WS_IDLE;
            cur_lba       <= 32'd0;
            sectors_read  <= 32'd0;
            sd_lba        <= 32'd0;
            wr_ptr        <= {ADDR_WIDTH{1'b0}};
            lo_pending    <= 1'b0;
            lo_byte       <= 8'd0;
            wr_gray       <= {ADDR_WIDTH{1'b0}};
            rd_gray_sync1 <= {ADDR_WIDTH{1'b0}};
            rd_gray_sync2 <= {ADDR_WIDTH{1'b0}};
        end else begin
            // 读指针格雷码同步进写域（2FF）
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
            // 写指针格雷码源域寄存
            wr_gray       <= to_gray(wr_ptr);

            if (!play_enable) begin
                // 播放停止：中止流，指针清零；重新拉高 play_enable 即从头重播
                wstate       <= WS_IDLE;
                wr_ptr       <= {ADDR_WIDTH{1'b0}};
                lo_pending   <= 1'b0;
                sectors_read <= 32'd0;
            end else begin
                case (wstate)
                WS_IDLE: begin
                    if (start_lba != 32'd0 && total_sectors != 32'd0) begin
                        cur_lba      <= start_lba;
                        // sd_req 为 WS_REQ 组合输出, sd_lba 必须与 req 同拍有效:
                        // 进入 WS_REQ 即预载, 否则首拍 arbiter 采到旧 lba(0)
                        // 会发出扇区 0 事务(零字节)顶掉首扇区数据。
                        sd_lba       <= start_lba;
                        sectors_read <= 32'd0;
                        wr_ptr       <= {ADDR_WIDTH{1'b0}};
                        lo_pending   <= 1'b0;
                        wstate       <= WS_REQ;
                    end
                end
                WS_REQ: begin
                    if (!sd_busy && !wr_pause) begin
                        sd_lba <= cur_lba;
                        wstate <= WS_FILL;
                    end
                end
                WS_FILL: begin
                    if (sd_valid) begin
                        if (!lo_pending) begin
                            lo_byte    <= sd_byte;      // 低字节先到
                            lo_pending <= 1'b1;
                        end else begin
                            wr_ptr         <= wr_ptr + 1'b1;
                            lo_pending     <= 1'b0;
                        end
                    end
                    if (sd_done) begin
                        lo_pending <= 1'b0;             // 容错：错误中止时清半字状态
                        if (sd_error != 8'd0) begin
                            wstate <= WS_END;           // 扇区出错：停止流
                        end else begin
                            sectors_read <= sectors_read + 1'b1;
                            cur_lba      <= cur_lba + 1'b1;
                            sd_lba       <= cur_lba + 1'b1;  // 与 req 同拍(见 WS_IDLE 注释)
                            if (sectors_read + 1'b1 >= total_sectors)
                                wstate <= WS_END;       // 全部读完
                            else
                                wstate <= WS_REQ;       // 读下一扇区
                        end
                    end
                end
                WS_END: begin
                    // 终态：等 play_enable 拉低（由上方全局规则回 IDLE）
                end
                default: wstate <= WS_IDLE;
                endcase
            end
        end
    end

    // ---------------- 读侧 ----------------
    // BRAM 读口与 async_pixel_fifo 同构：读使能 + 专用输出寄存器，静音 0 只允许
    // 在 BRAM 输出寄存器之后混选。若把 buffer[rd_ptr] 与常量 0 在寄存器前混选，
    // TD 无法把输出寄存器吸收进 BRAM，只能按异步读退化为分布式 LUT RAM。
    wire rd_fire = sample_tick && sample_ready && play_enable &&
                   (level_rd >= SAMPLES_PER_SECTOR || (ended_sync2 && level_rd > 0));
    reg [15:0] rd_data_r;
    reg        rd_take_r;
    reg        rd_valid_r;

    always @(posedge rd_clk or negedge rd_sync_rst_n) begin
        if (!rd_sync_rst_n) begin
            rd_ptr         <= {ADDR_WIDTH{1'b0}};
            rd_gray        <= {ADDR_WIDTH{1'b0}};
            wr_gray_sync1  <= {ADDR_WIDTH{1'b0}};
            wr_gray_sync2  <= {ADDR_WIDTH{1'b0}};
            ended_sync1    <= 1'b0;
            ended_sync2    <= 1'b0;
            rd_data_r      <= 16'd0;
            rd_take_r      <= 1'b0;
            rd_valid_r     <= 1'b0;
            sample_out     <= 16'sd0;
            sample_valid   <= 1'b0;
            sample_counter <= 32'd0;
        end else begin
            // 写指针格雷码同步进读域（2FF）
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
            // 读指针格雷码源域寄存
            rd_gray       <= to_gray(rd_ptr);
            // ended 标志 2FF
            ended_sync1   <= ended_w;
            ended_sync2   <= ended_sync1;

            // 第一级：BRAM 同步读 + 出样语义判定
            if (rd_fire) begin
                rd_ptr         <= rd_ptr + 1'b1;
                rd_data_r      <= buffer[rd_ptr];
                sample_counter <= sample_counter + 1'b1;
            end
            if (sample_tick && sample_ready && play_enable) begin
                rd_take_r  <= rd_fire;
                rd_valid_r <= rd_fire || !ended_sync2;
            end else begin
                rd_take_r  <= 1'b0;
                rd_valid_r <= 1'b0;
            end

            // 第二级：数据/有效同拍出（整体比旧版晚 1 个 rd_clk 拍，二者同拍）
            sample_valid <= rd_valid_r;
            sample_out   <= rd_take_r ? rd_data_r : 16'sd0;

            if (!play_enable) begin
                rd_ptr         <= {ADDR_WIDTH{1'b0}};
                sample_counter <= 32'd0;
            end
        end
    end

    // 排空结束标志寄存一拍(见 stream_active 注释): 覆盖末样本 valid 拍。
    // 须同时等第一级 rd_valid_r 走完 —— 末次 take 拍 level 即归零, 但末样本
    // valid 在次拍才出现, 仅看 level 会令 stream_active 与末 valid 重叠一拍。
    always @(posedge rd_clk or negedge rd_sync_rst_n) begin
        if (!rd_sync_rst_n)
            drain_done_r <= 1'b0;
        else
            drain_done_r <= ended_sync2 && (level_rd == {ADDR_WIDTH{1'b0}})
                            && !rd_valid_r;
    end
endmodule
