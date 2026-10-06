`timescale 1ns / 1ps
// ============================================================================
// sdram_cmd_engine — 片上SDRAM(EG_PHY_SDRAM_2M_32, 2M×32bit)命令引擎
//
// 职责:
//   1. 上电初始化序列: 200us掉电等待(CKE=0) -> PRECHARGE ALL -> AUTO REFRESH×2
//      -> MODE REGISTER SET(BL=8顺序突发, CAS=3) -> init_done
//   2. 单次读/写事务(闭合页策略): ACT -> tRCD -> READ/WRITE(8拍突发) ->
//      tWR(写) / 突发尾(读) -> PRECHARGE -> tRP -> 完成脉冲
//      * 写: 仅第1拍携带数据与字节掩码dm, 其余7拍dm=4'b1111全屏蔽,
//        借此实现"半字(16bit)写入32bit字"而无需读-改-写
//      * 读: 按CAS=3在命令后CL个引擎周期捕获第1拍数据(V3实测前移一拍), 其余拍忽略
//        (突发数据全部被上层行缓冲利用)
//   3. 刷新服务: IDLE状态下 refresh_req 优先于读写请求,
//      完成后给出 refresh_ack 单拍脉冲
//
// 双相时钟读捕获时序(V3实测修正):
//   本引擎由 clk(0°)驱动, 原语由外部送入的 sdram_clk(180°)驱动。
//   原语在180°沿采样命令并于180°沿更新读数据dq, 控制逻辑在0°沿采样dq。
//   片内SDRAM die 的首拍数据比 EM638325 CL 语义早一拍出现(2026-09-13
//   V2 地址自编码 bit 上板实证, 旧窗口采到邻字 beat shift +1):
//   READ命令在0°沿E0发出, 原语在P0=E0+4(180°沿)寄存, 首拍数据在
//   P0+(CL-1)*8ns=E0+CL*8ns(180°沿)出现并保持一个周期, 引擎在
//   E0+CL*8ns(0°沿)采样正好命中首拍。CL=3 -> 命令+3拍。
//
// 地址结构(21位字地址, 由原语引脚位宽推导):
//   req_addr[20:19]=bank, req_addr[18:8]=row(11位,2048行), req_addr[7:0]=col(8位,256列)
//
// 命令编码(cs_n/ras_n/cas_n/we_n):
//   DESELECT=1xxx, NOP=0111, ACTIVE=0011, READ=0101, WRITE=0100,
//   PRECHARGE=0010, AUTO_REFRESH=0001, MRS=0000
//
// 时序参数推导(125MHz, tCK=8ns, 参数来源: EM638325规格书Rev.3.2 Table 16):
//   200us上电稳定  -> T_INIT = 200000/8     = 25000
//   tRP=21ns(最差档) -> T_RP = ceil(21/8)   = 3 (24ns)
//   tRCD=21ns(最差档)-> T_RCD = ceil(21/8)  = 3 (24ns)
//   tWR=2tCK        -> T_WR  = 2
//   tMRD=2tCK       -> T_MRD = 2
//   tRFC=63ns(最差档)-> T_RFC = ceil(63/8)  = 8 (64ns)
//   tCK(CL=2)>=9ns(-7档)/10ns(-5,-6档) > 8ns: 125MHz下CL=2不满足数据手册!
//   tCK(CL=3)>=5/6/7ns <= 8ns: 必须用CAS Latency=3 (MRS A[6:4]=011)
//
// 双相时钟读捕获时序(本实现依据, V3实测修正):
//   本引擎由 clk(0°)驱动, 原语由外部送入的 sdram_clk(180°)驱动。
//   引擎在0°沿E0发出READ命令, 原语在最近的180°沿P0=E0+4ns寄存命令。
//   片内 die 首拍数据比 EM638325 CL 语义早一拍(P0+(CL-1)*8ns出现),
//   引擎在0°沿 E0+CL*8ns 采样。实现: ST_RD_CMD(命令+1) ->
//   ST_RD_CL等CL-2拍(命令+2~+CL-1) -> ST_RD_CAP捕获(命令+CL) ->
//   ST_RD_BEATS(剩余7拍)。
//   * 反相时钟下命令永远提前半周期建立、数据永远提前半周期稳定, 消除
//     同相方案在原语控制端口的hold违例(50MHz同相版实测 HWNS=-0.241ns)。
// ============================================================================
module sdram_cmd_engine #(
    parameter integer T_INIT    = 25000, // 上电稳定 200us @125MHz
    parameter integer T_RP      = 3,     // PRECHARGE -> ACTIVE (21ns -> 24ns)
    parameter integer T_RCD     = 3,     // ACTIVE -> READ/WRITE (21ns -> 24ns)
    parameter integer T_WR      = 2,     // WRITE末拍 -> PRECHARGE (2tCK)
    parameter integer T_MRD     = 2,     // MRS -> 下一命令 (2tCK)
    parameter integer T_RFC     = 8,     // AUTO REFRESH周期 (63ns -> 64ns)
    parameter integer CAS_LAT   = 3,     // 读延迟 CL=3 (125MHz下CL=2不满足tCK最小值)
    parameter integer DQ_LAT    = 1,     // [V0] 读回 DQ 预捕获级引入的滞后拍数
    parameter integer BURST_LEN = 8      // 突发长度(BL=8, 顺序)
)(
    input  wire        clk,
    input  wire        rst_n,

    output reg         init_done,       // 初始化完成(置位后保持)

    input  wire        refresh_req,     // 电平请求(保持到refresh_ack)
    output reg         refresh_ack,     // 单拍确认脉冲

    // ---- 操作请求(单发, 每次读或写一个32bit字) ----
    input  wire        req_valid,
    output wire        req_ready,       // IDLE且无刷新待处理时可接收
    input  wire        req_write,       // 1=写, 0=读
    input  wire [20:0] req_addr,        // 字地址 {ba[1:0], row[10:0], col[7:0]}
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_dm,          // 写字节掩码(1=屏蔽该字节)

    // ---- 操作完成 ----
    output reg         resp_valid,      // 单拍脉冲(读/写事务全部完成)
    output reg         resp_write,      // 响应对应的操作类型
    output reg  [31:0] resp_rdata,      // 读突发第1拍数据

    // ---- 读突发逐拍输出(BL=8, 全部利用, 供上层行缓冲捕获) ----
    output reg         beat_valid,      // 单拍脉冲, 连续BL拍
    output reg  [31:0] beat_data,
    output reg  [20:0] beat_addr,       // 该拍对应的字地址(块内递增)

    // ---- SDRAM原语引脚(全部寄存器输出) ----
    output reg         sdr_cke,
    output reg         sdr_cs_n,
    output reg         sdr_ras_n,
    output reg         sdr_cas_n,
    output reg         sdr_we_n,
    output reg  [10:0] sdr_addr,
    output reg  [1:0]  sdr_ba,
    output reg  [3:0]  sdr_dm,
    output reg  [31:0] sdr_dq_out,
    output reg         sdr_dq_oe,
    input  wire [31:0] sdr_dq_in
);

    // MRS值: A[2:0]=100(BL=8), A[3]=0(顺序突发), A[6:4]=011(CAS=3), 其余0
    localparam [10:0] MRS_VAL    = 11'h034;
    localparam [10:0] PRE_ALL_A  = 11'h400;  // A10=1: 全bank预充电
    localparam [3:0]  BL_MINUS_1 = BURST_LEN - 1;

    localparam [4:0]
        ST_PWR_UP   = 5'd0,   // 200us, CKE=0, DESELECT
        ST_CKE_ON   = 5'd1,   // CKE拉高, DESELECT保持
        ST_PRE_ALL  = 5'd2,   // PRECHARGE ALL(命令可见拍)
        ST_TRP_A    = 5'd3,
        ST_REF_A    = 5'd4,   // 第1次AUTO REFRESH
        ST_TRFC_A   = 5'd5,
        ST_REF_B    = 5'd6,   // 第2次AUTO REFRESH
        ST_TRFC_B   = 5'd7,
        ST_MRS      = 5'd8,   // 模式寄存器设置
        ST_TMRD     = 5'd9,
        ST_IDLE     = 5'd10,
        ST_ACT      = 5'd11,  // ACTIVE(命令可见拍)
        ST_TRCD     = 5'd12,
        ST_WR_BEAT0 = 5'd13,  // WRITE命令+第1拍数据(可见拍)
        ST_WR_BURST = 5'd14,  // 第2~8拍, dm全屏蔽
        ST_TWR      = 5'd15,
        ST_RD_CMD   = 5'd16,  // READ命令(可见拍)
        ST_RD_CL    = 5'd17,  // 等CL-1拍
        ST_RD_CAP   = 5'd18,  // 命令+CL+1拍捕获突发第1拍
        ST_RD_BEATS = 5'd19,  // 捕获突发第2~8拍
        ST_PRE      = 5'd20,  // PRECHARGE(命令可见拍)
        ST_TRP_B    = 5'd21,
        ST_DONE     = 5'd22,  // 完成脉冲
        ST_REF_S    = 5'd23,  // 刷新服务(命令可见拍)
        ST_TRFC_C   = 5'd24,  // 刷新服务tRFC等待
        ST_REF_W    = 5'd25;  // 等待refresh_req撤销(握手延迟)

    reg  [4:0]  state;
    reg  [14:0] cnt;          // 通用等待计数(25000 < 2^15)
    reg  [3:0]  burst_cnt;
    reg  [3:0]  beat_idx;     // 读突发拍序号

    reg         op_write;
    reg  [20:0] op_addr;
    reg  [31:0] op_wdata;
    reg  [3:0]  op_dm;

    wire [1:0]  op_ba  = op_addr[20:19];
    wire [10:0] op_row = op_addr[18:8];
    wire [7:0]  op_col = op_addr[7:0];

    // ---- [E1/A4-2 行开放链 2026-09-27] 同物理行(bank+row)连续读突发免
    //      预充电/再激活: 行重填(fb 整行 40 次突发)原每突发付
    //      ACT+tRCD+PRE+tRP+DONE ≈10 拍开销(20 拍/突发 → 40 突发 ≈840 拍),
    //      链后末拍直接接下一 READ(≈11 拍/突发 → ≈450 拍/行)。
    //      链条件: 末数据拍 ∧ 无刷新待处理 ∧ 下一请求为读 ∧ 同 bank+row
    //      ∧ 行仍开放。写事务恒闭页(不变), 刷新经 PRE ALL 先关行(下)。
    reg         row_valid;
    reg  [12:0] row_id;        // {ba[1:0], row[10:0]}
    reg         pre_ref;       // PRE 后转刷新(行开放时刷新先关行)
    wire        rd_chain = (state == ST_RD_BEATS) && (beat_idx == BL_MINUS_1) &&
                           !refresh_req && req_valid && !req_write &&
                           row_valid && (req_addr[20:8] == row_id);

    assign req_ready = ((state == ST_IDLE) && !refresh_req) || rd_chain;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_PWR_UP;
            cnt        <= 15'd0;
            burst_cnt  <= 4'd0;
            init_done  <= 1'b0;
            refresh_ack<= 1'b0;
            resp_valid <= 1'b0;
            resp_write <= 1'b0;
            resp_rdata <= 32'd0;
            op_write   <= 1'b0;
            op_addr    <= 21'd0;
            op_wdata   <= 32'd0;
            op_dm      <= 4'b1111;
            beat_valid <= 1'b0;
            beat_data  <= 32'd0;
            beat_addr  <= 21'd0;
            beat_idx   <= 4'd0;
            row_valid  <= 1'b0;           // [A4-2]
            row_id     <= 13'd0;
            pre_ref    <= 1'b0;
            sdr_cke    <= 1'b0;
            sdr_cs_n   <= 1'b1;           // DESELECT
            sdr_ras_n  <= 1'b1;
            sdr_cas_n  <= 1'b1;
            sdr_we_n   <= 1'b1;
            sdr_addr   <= 11'd0;
            sdr_ba     <= 2'b00;
            sdr_dm     <= 4'b1111;
            sdr_dq_out <= 32'd0;
            sdr_dq_oe  <= 1'b0;
        end else begin
            // 默认: 下一拍发NOP; 单拍脉冲信号清零
            sdr_cs_n    <= 1'b0;
            sdr_ras_n   <= 1'b1;
            sdr_cas_n   <= 1'b1;
            sdr_we_n    <= 1'b1;
            resp_valid  <= 1'b0;
            refresh_ack <= 1'b0;
            beat_valid  <= 1'b0;

            case (state)
            // ---------------- 初始化 ----------------
            ST_PWR_UP: begin
                sdr_cs_n <= 1'b1;              // 掉电等待期DESELECT
                if (cnt == T_INIT-1) begin
                    cnt     <= 15'd0;
                    state   <= ST_CKE_ON;
                    sdr_cke <= 1'b1;       // CKE拉高, cs_n保持1(DESELECT)
                end else begin
                    cnt <= cnt + 15'd1;
                end
            end

            ST_CKE_ON: begin
                if (cnt == 1) begin
                    cnt      <= 15'd0;
                    state    <= ST_PRE_ALL;
                    // 下一拍: PRECHARGE ALL
                    sdr_cs_n <= 1'b0; sdr_ras_n <= 1'b0;
                    sdr_cas_n<= 1'b1; sdr_we_n  <= 1'b0;
                    sdr_addr <= PRE_ALL_A; sdr_ba <= 2'b00;
                end else begin
                    cnt <= cnt + 15'd1;
                end
            end

            ST_PRE_ALL: begin              // PRE可见拍 -> 等tRP
                state <= ST_TRP_A;
                cnt   <= 15'd0;
            end

            ST_TRP_A: begin
                if (cnt == T_RP-1) begin
                    cnt      <= 15'd0;
                    state    <= ST_REF_A;
                    // 下一拍: AUTO REFRESH
                    sdr_cs_n <= 1'b0; sdr_ras_n <= 1'b0;
                    sdr_cas_n<= 1'b0; sdr_we_n  <= 1'b1;
                end else begin
                    cnt <= cnt + 15'd1;
                end
            end

            ST_REF_A: begin state <= ST_TRFC_A; cnt <= 15'd0; end

            ST_TRFC_A: begin
                if (cnt == T_RFC-1) begin
                    cnt      <= 15'd0;
                    state    <= ST_REF_B;
                    sdr_cs_n <= 1'b0; sdr_ras_n <= 1'b0;
                    sdr_cas_n<= 1'b0; sdr_we_n  <= 1'b1;
                end else begin
                    cnt <= cnt + 15'd1;
                end
            end

            ST_REF_B: begin state <= ST_TRFC_B; cnt <= 15'd0; end

            ST_TRFC_B: begin
                if (cnt == T_RFC-1) begin
                    cnt      <= 15'd0;
                    state    <= ST_MRS;
                    // 下一拍: MODE REGISTER SET
                    sdr_cs_n <= 1'b0; sdr_ras_n <= 1'b0;
                    sdr_cas_n<= 1'b0; sdr_we_n  <= 1'b0;
                    sdr_ba   <= 2'b00; sdr_addr <= MRS_VAL;
                end else begin
                    cnt <= cnt + 15'd1;
                end
            end

            ST_MRS: begin state <= ST_TMRD; cnt <= 15'd0; end

            ST_TMRD: begin
                if (cnt == T_MRD-1) begin
                    cnt       <= 15'd0;
                    state     <= ST_IDLE;
                    init_done <= 1'b1;
                end else begin
                    cnt <= cnt + 15'd1;
                end
            end

            // ---------------- 空闲/仲裁 ----------------
            ST_IDLE: begin
                if (refresh_req) begin
                    // [A4-2] 行开放时刷新须先 PRE ALL 关行(AUTO REFRESH 要求全
                    //   bank 预充电): PRE → tRP → ST_REF_S; 行已闭则原路直入。
                    if (row_valid) begin
                        state    <= ST_PRE;
                        pre_ref  <= 1'b1;
                        row_valid<= 1'b0;
                        sdr_cs_n <= 1'b0; sdr_ras_n <= 1'b0;
                        sdr_cas_n<= 1'b1; sdr_we_n  <= 1'b0;
                        sdr_addr <= PRE_ALL_A; sdr_ba <= 2'b00;
                    end else begin
                        state    <= ST_REF_S;
                        sdr_cs_n <= 1'b0; sdr_ras_n <= 1'b0;
                        sdr_cas_n<= 1'b0; sdr_we_n  <= 1'b1;
                    end
                end else if (req_valid) begin
                    op_write <= req_write;
                    op_addr  <= req_addr;
                    op_wdata <= req_wdata;
                    op_dm    <= req_dm;
                    state    <= ST_ACT;
                    cnt      <= 15'd0;
                    // 下一拍: ACTIVE
                    sdr_cs_n <= 1'b0; sdr_ras_n <= 1'b0;
                    sdr_cas_n<= 1'b1; sdr_we_n  <= 1'b1;
                    sdr_ba   <= req_addr[20:19];
                    sdr_addr <= req_addr[18:8];
                end
            end

            ST_ACT: begin
                state <= ST_TRCD; cnt <= 15'd0;
                row_valid <= 1'b1;          // [A4-2] 行开放登记
                row_id    <= op_addr[20:8];
            end

            ST_TRCD: begin
                if (cnt == T_RCD-1) begin
                    cnt <= 15'd0;
                    if (op_write) begin
                        state      <= ST_WR_BEAT0;
                        burst_cnt  <= BL_MINUS_1;
                        // 下一拍: WRITE命令 + 第1拍数据
                        sdr_cs_n   <= 1'b0; sdr_ras_n <= 1'b1;
                        sdr_cas_n  <= 1'b0; sdr_we_n  <= 1'b0;
                        sdr_ba     <= op_ba;
                        sdr_addr   <= {3'b000, op_col};
                        sdr_dq_oe  <= 1'b1;
                        sdr_dq_out <= op_wdata;
                        sdr_dm     <= op_dm;
                    end else begin
                        state      <= ST_RD_CMD;
                        // 下一拍: READ命令(列地址按突发块对齐, 块内8字不跨行)
                        sdr_cs_n   <= 1'b0; sdr_ras_n <= 1'b1;
                        sdr_cas_n  <= 1'b0; sdr_we_n  <= 1'b1;
                        sdr_ba     <= op_ba;
                        sdr_addr   <= {3'b000, op_addr[7:3], 3'b000};
                        sdr_dq_oe  <= 1'b0;
                        sdr_dm     <= 4'b0000;
                    end
                end else begin
                    cnt <= cnt + 15'd1;
                end
            end

            // ---------------- 写事务 ----------------
            ST_WR_BEAT0: begin             // WRITE+beat0可见拍
                state      <= ST_WR_BURST;
                // 下一拍起: 第2~8拍, 数据无关, dm全屏蔽
                sdr_dq_out <= 32'd0;
                sdr_dm     <= 4'b1111;
            end

            ST_WR_BURST: begin
                if (burst_cnt == 4'd1) begin
                    burst_cnt <= 4'd0;
                    state     <= ST_TWR;
                    cnt       <= 15'd0;
                    sdr_dq_oe <= 1'b0;      // 突发结束, 释放总线
                    sdr_dm    <= 4'b1111;
                end else begin
                    burst_cnt <= burst_cnt - 4'd1;
                end
            end

            ST_TWR: begin
                if (cnt == T_WR-1) begin
                    cnt      <= 15'd0;
                    state    <= ST_PRE;
                    // 下一拍: PRECHARGE ALL
                    sdr_cs_n <= 1'b0; sdr_ras_n <= 1'b0;
                    sdr_cas_n<= 1'b1; sdr_we_n  <= 1'b0;
                    sdr_addr <= PRE_ALL_A; sdr_ba <= 2'b00;
                end else begin
                    cnt <= cnt + 15'd1;
                end
            end

            // ---------------- 读事务 ----------------
            // 时序推导(双相时钟, CL=3, V3实测修正):
            //   t0     : 引擎0°沿发READ命令(ST_TRCD末拍输出, 原语在t0+4寄存)
            //   t0+4   : 原语180°沿寄存READ, 内部rd_cnt<=CL=3
            //   t0+20  : 原语180°沿输出第1拍数据(寄存后第CL-1个沿, 片内die
            //            实测比EM638325 CL语义早一拍)并保持一个周期
            //   t0+24  : 引擎0°沿捕获第1拍(=命令后CL个引擎周期)
            // 因此ST_RD_CMD后需ST_RD_CL等待CL-2拍再进入ST_RD_CAP采样。
            //
            // V3 修正(2026-09-13 上板实测, V2 地址自编码 bit 证据):
            //   片内SDRAM die 的首拍数据比 EM638325 CL 语义早一拍出现,
            //   旧窗口(命令+CL+1)采到的是第2个字(beat shift +1, V1/V2 上板
            //   读回值即邻字自编码)。捕获窗口前移一拍(等 CL-2 拍),
            //   行为模型(tb/EG_PHY_SDRAM_2M_32.v)同步改为提前一拍输出。
            //
            // [task_026 V0] 读回 DQ 已在 sdram_clk 域预捕获一级(见
            //   sdram_frame_buffer.v 的 dq_m), 该级给数据通路引入固定滞后,
            //   故本窗口需相应后移 DQ_LAT 拍。DQ_LAT 的取值(0/1)由
            //   loader 集成台的 307200 点黄金读回裁决, 不按半周期推定 ——
            //   原因: 上述"模型提前一拍"与本滞后叠加后的净偏移只能实测。
            ST_RD_CMD: begin state <= ST_RD_CL; cnt <= 15'd0; end

            ST_RD_CL: begin              // 等CL-2+DQ_LAT拍(命令+2 ~ 命令+CL-1)
                if (cnt == CAS_LAT-3+DQ_LAT) begin
                    cnt     <= 15'd0;
                    state   <= ST_RD_CAP;
                end else begin
                    cnt <= cnt + 15'd1;
                end
            end

            ST_RD_CAP: begin             // 命令+CL拍: 突发第1拍数据在本拍总线上(V3前移一拍)
                resp_rdata <= sdr_dq_in;
                beat_valid <= 1'b1;
                beat_data  <= sdr_dq_in;
                beat_addr  <= {op_addr[20:3], 3'b000};
                beat_idx   <= 4'd1;
                state      <= ST_RD_BEATS;
            end

            ST_RD_BEATS: begin             // 突发第2~8拍, 逐拍输出
                beat_valid <= 1'b1;
                beat_data  <= sdr_dq_in;
                beat_addr  <= {op_addr[20:3], beat_idx[2:0]};
                if (beat_idx == BL_MINUS_1) begin
                    beat_idx <= 4'd0;
                    if (rd_chain) begin
                        // [A4-2] 行开放链: 免 PRE/tRP/ACT/tRCD, 直接发下一 READ
                        //   (命令本拍出口寄存, 与 TRCD 出口发读同构; 列取自新请求)
                        state    <= ST_RD_CMD;
                        op_addr  <= req_addr;
                        op_write <= 1'b0;
                        sdr_cs_n <= 1'b0; sdr_ras_n <= 1'b1;
                        sdr_cas_n<= 1'b0; sdr_we_n  <= 1'b1;
                        sdr_ba   <= req_addr[20:19];
                        sdr_addr <= {3'b000, req_addr[7:3], 3'b000};
                        sdr_dq_oe<= 1'b0;
                        sdr_dm   <= 4'b0000;
                    end else begin
                        state    <= ST_PRE;
                        sdr_cs_n <= 1'b0; sdr_ras_n <= 1'b0;
                        sdr_cas_n<= 1'b1; sdr_we_n  <= 1'b0;
                        sdr_addr <= PRE_ALL_A; sdr_ba <= 2'b00;
                    end
                end else begin
                    beat_idx <= beat_idx + 4'd1;
                end
            end

            // ---------------- 收尾 ----------------
            ST_PRE: begin
                state <= ST_TRP_B; cnt <= 15'd0;
                row_valid <= 1'b0;          // [A4-2] 预充电关行
            end

            ST_TRP_B: begin
                if (cnt == T_RP-1) begin
                    cnt   <= 15'd0;
                    // [A4-2] 行开放时的刷新: PRE 后转刷新服务(否则原路 DONE)
                    state <= pre_ref ? ST_REF_S : ST_DONE;
                    if (pre_ref) pre_ref <= 1'b0;
                end else begin
                    cnt <= cnt + 15'd1;
                end
            end

            ST_DONE: begin
                resp_valid <= 1'b1;
                resp_write <= op_write;
                state      <= ST_IDLE;
            end

            // ---------------- 刷新服务 ----------------
            ST_REF_S: begin state <= ST_TRFC_C; cnt <= 15'd0; end

            ST_TRFC_C: begin
                if (cnt == T_RFC-1) begin
                    cnt         <= 15'd0;
                    state       <= ST_REF_W;
                    refresh_ack <= 1'b1;
                end else begin
                    cnt <= cnt + 15'd1;
                end
            end

            ST_REF_W: begin
                // ack发出后定时器需晚一拍才撤销refresh_req,
                // 此处等待req真实撤销, 避免回IDLE时误发第二次刷新
                if (!refresh_req) state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
            endcase
        end
    end

endmodule