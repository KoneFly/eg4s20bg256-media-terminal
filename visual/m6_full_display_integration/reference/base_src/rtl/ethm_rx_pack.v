`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// 051 契约收包机(app_clk 25MHz 域)。输入来自字节 FIFO(ethm_rx_capture 在前端
// 125MHz 侧打好的标签), 每收到一个完整帧输出 6 个 32bit 记录字, 交给统计域做
// 序号/epoch/连续性判定。字段偏移、判定口径、记录字布局与搬域前完全一致。
//
// 输入流的约定(由 ethm_bafifo 的 kind 给出, TEMAC 的边带信号不再跨域):
//   kind=2'b00 帧内数据字节;  kind=2'b01 帧内最后一个数据字节;
//   kind=2'b10 元数据, data[7:0]={mac_crc_bad, 6'b0, truncated}。
//   * 帧尾由 kind=01 交付 => 原来"dv 落低就结束一帧"的判据换成"读到 kind=01",
//     字节的连续性由标记保证, 不再依赖快侧的时序。
//   * 字节序号在 kind=01 / kind=10 之后的那个字重新从 0 开始(dv_d 只在吞掉一个
//     kind=00 时置 1), 这就是原来"绝不把帧中字节误当帧首"的重挂规则: 现在帧首
//     是标记给的, 不可能认错。
//   * 原来在 ST_FLAG 里"有界地等 TEMAC 整帧结论(最多 31 拍), 等不到就按坏帧算)
//     的行为搬到了 ethm_rx_capture; 本模块的 ST_FLAG 现在等有界的元数据字,
//     同样留 31 拍上限, 超时按 mac_crc_bad=1 处理(不能让状态机挂死)。
//
// 读侧握手(必须让后人看到): rd_data 是寄存输出, 相差一拍。所以本模块只在
// "rd_vld=1 且这一拍真的把这个字用掉"时才发 rd_en; 槽空时发的是取字请求, 字
// 一到条件自动收回。用 !rd_empty 当"有数据"会重复解析同一个字节或吃掉陈旧字。
//
// 背压期间的行为: ST_PUSH 期间不发 rd_en, 下一帧的字节就在 FIFO 里排队(512 深
// 够放一整帧 + 元数据), 既不丢字节也不会把中间字节当帧首; 记录 FIFO 装不下整条
// 记录时仍然按原来的 push_dropped / busy_dropped 计数, 不静默。
//------------------------------------------------------------------------------
module ethm_rx_pack (
    input  wire        clk,          // app_clk
    input  wire        rst,          // app_rst

    input  wire [9:0]  fifo_rd_data,
    input  wire [1:0]  fifo_rd_kind,
    input  wire        fifo_rd_vld,
    input  wire        fifo_rd_last,
    input  wire        fifo_rd_empty,
    output wire        fifo_rd_en,

    input  wire [47:0] expect_da,
    input  wire        push_ready,

    output reg         push_req,
    output reg  [31:0] push_word,
    output reg         push_dropped,
    output reg         busy_dropped,
    // 本帧因字节 FIFO 溢出而丢掉过字节(app 域单拍脉冲)。
    // 前端 125MHz 侧的溢出是单拍事件, 直接送到 25MHz 域一定会漏, 所以按"帧"
    // 经元数据的 truncated 位(位0, 语义就是"有字被溢出丢弃")上报。
    output reg         of_evt
);
    localparam [8:0] PAY_FIRST = 9'd46;
    localparam [8:0] PAY_LAST  = 9'd301;
    localparam [8:0] CRC_FIRST = 9'd302;
    localparam [8:0] EXP_LEN   = 9'd306;

    localparam [1:0] KIND_DATA = 2'b00;
    localparam [1:0] KIND_LAST = 2'b01;
    localparam [1:0] KIND_META = 2'b10;

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_RUN  = 3'd1;
    localparam [2:0] ST_FLAG = 3'd2;
    localparam [2:0] ST_PUSH = 3'd3;

    reg [2:0]  state;
    reg [8:0]  bi;
    reg        dv_d;
    reg [8:0]  byte_len;
    reg [4:0]  flag_wait;
    reg [2:0]  push_count;

    reg        da_bad_r;
    reg        etype_bad_r;
    reg        content_bad_r;
    reg        app_crc_bad_r;
    reg        hdr_bad_r;
    reg        mac_crc_bad_r;
    reg        len_err_r;
    reg        of_r;      // 元数据 truncated 位: 本帧有字被溢出丢弃(计入 len 错)
    reg [7:0]  res_or;

    reg [31:0] magic_r;
    reg [7:0]  version_r;
    reg [7:0]  type_r;
    reg [15:0] plen_r;
    reg [31:0] epoch_r;
    reg [31:0] seq_r;
    reg [63:0] first_r;
    reg [15:0] count_r;
    reg [15:0] flags_r;
    reg [31:0] crc_rx;

    // ---------------- 流译码 ----------------
    wire [7:0] rx_byte  = fifo_rd_data[7:0];
    wire       is_meta  = fifo_rd_vld && (fifo_rd_kind == KIND_META);
    // dvalid: 槽里是一个还没解析的数据字节(原来这一拍的 rx_data_vld)
    wire       dvalid   = fifo_rd_vld && (fifo_rd_kind != KIND_META);
    wire       last_now = fifo_rd_vld && fifo_rd_last;
    wire       in_bytes = (state == ST_IDLE) || (state == ST_RUN);

    // 当前呈现字节在帧内的序号(组合, 与 rx_byte 同拍有效)
    wire [8:0] cur_bi = dv_d ? (bi + 9'd1) : 9'd0;
    wire       accept = dvalid;

    // 读请求: 只在"本拍真的把这个字用掉"或"槽空要取字"时发出
    wire ack_byte  = in_bytes && dvalid;                 // 逐字节解析掉
    wire ack_stale = in_bytes && is_meta;                // 迟到的元数据: 丢弃
    wire ack_flag  = (state == ST_FLAG) && fifo_rd_vld;  // 等元数据期间一律吃掉
    wire want_fetch= (in_bytes || (state == ST_FLAG)) && (!fifo_rd_vld);
    assign fifo_rd_en = ack_byte || ack_stale || ack_flag || want_fetch;

    // 本帧之后还有没有更新的帧在排队(busy_dropped 的判据, 口径同原来的 rx_data_vld)
    wire newer_frame_pend = (!fifo_rd_empty)
                          || (fifo_rd_vld && (fifo_rd_kind != KIND_META));

    reg [7:0] exp_da_byte;
    always @(*) begin
        case (cur_bi)
            9'd0:    exp_da_byte = expect_da[47:40];
            9'd1:    exp_da_byte = expect_da[39:32];
            9'd2:    exp_da_byte = expect_da[31:24];
            9'd3:    exp_da_byte = expect_da[23:16];
            9'd4:    exp_da_byte = expect_da[15:8];
            default: exp_da_byte = expect_da[7:0];
        endcase
    end

    // ---------------- 载荷内容校验 ----------------
    wire [8:0]  pay_off   = cur_bi - PAY_FIRST;
    wire [31:0] pat_index = first_r[31:0] + {24'd0, pay_off[8:1]};
    wire [15:0] pat_val;
    ethm_pcm_pattern u_pattern (
        .sample_index (pat_index),
        .salt         (epoch_r[15:0]),
        .value        (pat_val)
    );
    wire [7:0] exp_pay_byte = cur_bi[0] ? pat_val[15:8] : pat_val[7:0];
    wire       pay_check    = accept && (cur_bi >= PAY_FIRST) && (cur_bi <= PAY_LAST);

    // ---------------- 应用 CRC32 ----------------
    wire        crc_en     = accept && (cur_bi >= 9'd14) && (cur_bi <= PAY_LAST);
    wire [31:0] crc_stored;
    ethm_crc32_ref u_crc (
        .clk        (clk),
        .rst        (rst),
        .load_init  (accept && !dv_d),
        .byte_valid (crc_en),
        .byte_in    (rx_byte),
        .crc        (crc_stored)
    );
    wire [31:0] crc_calc = ~crc_stored;

    always @(posedge clk) begin
        if (rst) begin
            state          <= ST_IDLE;
            bi             <= 9'd0;
            dv_d           <= 1'b0;
            byte_len       <= 9'd0;
            flag_wait      <= 5'd0;
            push_count     <= 3'd0;
            da_bad_r       <= 1'b0;
            etype_bad_r    <= 1'b0;
            content_bad_r  <= 1'b0;
            app_crc_bad_r  <= 1'b0;
            hdr_bad_r      <= 1'b0;
            mac_crc_bad_r  <= 1'b0;
            len_err_r      <= 1'b0;
            of_r         <= 1'b0;
            res_or         <= 8'd0;
            magic_r        <= 32'd0;
            version_r      <= 8'd0;
            type_r         <= 8'd0;
            plen_r         <= 16'd0;
            epoch_r        <= 32'd0;
            seq_r          <= 32'd0;
            first_r        <= 64'd0;
            count_r        <= 16'd0;
            flags_r        <= 16'd0;
            crc_rx         <= 32'd0;
            push_req       <= 1'b0;
            push_word      <= 32'd0;
            push_dropped   <= 1'b0;
            busy_dropped   <= 1'b0;
            of_evt      <= 1'b0;
        end
        else begin
            // 字节序号的延续性: 只有吞掉一个 kind=00 才算"上一拍还在帧内";
            // kind=01/kind=10 之后序号重新从 0 起(见文件头重挂规则)。
            dv_d         <= ack_byte && (fifo_rd_kind == KIND_DATA);
            push_req     <= 1'b0;
            push_dropped <= 1'b0;
            busy_dropped <= 1'b0;
            of_evt    <= 1'b0;

            case (state)
            // ---------- 帧首字节 ----------
            ST_IDLE: begin
                if (dvalid) begin
                    state         <= ST_RUN;
                    bi            <= 9'd0;
                    flag_wait     <= 5'd0;
                    da_bad_r      <= (rx_byte != exp_da_byte);
                    etype_bad_r   <= 1'b0;
                    content_bad_r <= 1'b0;
                    app_crc_bad_r <= 1'b0;
                    hdr_bad_r     <= 1'b0;
                    len_err_r     <= 1'b0;
                    of_r          <= 1'b0;
                    mac_crc_bad_r <= 1'b0;
                end
            end

            // ---------- 逐字节解析 ----------
            ST_RUN: begin
                if (dvalid) begin
                    bi <= cur_bi;
                    if (cur_bi < 9'd6)
                        da_bad_r <= da_bad_r | (rx_byte != exp_da_byte);
                    else if (cur_bi == 9'd12)
                        etype_bad_r <= (rx_byte != 8'h88);
                    else if (cur_bi == 9'd13)
                        etype_bad_r <= etype_bad_r | (rx_byte != 8'hB5);
                    else if (pay_check)
                        content_bad_r <= content_bad_r | (rx_byte != exp_pay_byte);

                    if ((cur_bi >= 9'd42) && (cur_bi <= 9'd45))
                        res_or <= res_or | rx_byte;

                    case (cur_bi)
                        9'd14:   magic_r[7:0]   <= rx_byte;
                        9'd15:   magic_r[15:8]  <= rx_byte;
                        9'd16:   magic_r[23:16] <= rx_byte;
                        9'd17:   magic_r[31:24] <= rx_byte;
                        9'd18:   version_r      <= rx_byte;
                        9'd19:   type_r         <= rx_byte;
                        9'd20:   plen_r[7:0]    <= rx_byte;
                        9'd21:   plen_r[15:8]   <= rx_byte;
                        9'd22:   epoch_r[7:0]   <= rx_byte;
                        9'd23:   epoch_r[15:8]  <= rx_byte;
                        9'd24:   epoch_r[23:16] <= rx_byte;
                        9'd25:   epoch_r[31:24] <= rx_byte;
                        9'd26:   seq_r[7:0]     <= rx_byte;
                        9'd27:   seq_r[15:8]    <= rx_byte;
                        9'd28:   seq_r[23:16]   <= rx_byte;
                        9'd29:   seq_r[31:24]   <= rx_byte;
                        9'd30:   first_r[7:0]   <= rx_byte;
                        9'd31:   first_r[15:8]  <= rx_byte;
                        9'd32:   first_r[23:16] <= rx_byte;
                        9'd33:   first_r[31:24] <= rx_byte;
                        9'd34:   first_r[39:32] <= rx_byte;
                        9'd35:   first_r[47:40] <= rx_byte;
                        9'd36:   first_r[55:48] <= rx_byte;
                        9'd37:   first_r[63:56] <= rx_byte;
                        9'd38:   count_r[7:0]   <= rx_byte;
                        9'd39:   count_r[15:8]  <= rx_byte;
                        9'd40:   flags_r[7:0]   <= rx_byte;
                        9'd41:   flags_r[15:8]  <= rx_byte;
                        9'd45:   hdr_bad_r <= (magic_r != 32'h4D36_5043)
                                           | (version_r != 8'd1)
                                           | (plen_r   != 16'd256)
                                           | (count_r  != 16'd128)
                                           | ((res_or | rx_byte) != 8'd0);
                        default: ;
                    endcase

                    if ((cur_bi >= CRC_FIRST) && (cur_bi <= 9'd305)) begin
                        case (cur_bi - CRC_FIRST)
                            9'd0:    crc_rx[7:0]    <= rx_byte;
                            9'd1:    crc_rx[15:8]   <= rx_byte;
                            9'd2:    crc_rx[23:16]  <= rx_byte;
                            default: begin
                                crc_rx[31:24] <= rx_byte;
                                app_crc_bad_r <= ({rx_byte, crc_rx[23:0]} != crc_calc);
                            end
                        endcase
                    end

                    // ---------- 帧尾标记: 本帧字节数就此定案 ----------
                    if (last_now) begin
                        byte_len      <= cur_bi + 9'd1;
                        len_err_r     <= ((cur_bi + 9'd1) != EXP_LEN);
                        mac_crc_bad_r <= 1'b0;
                        of_r       <= 1'b0;
                        state         <= ST_FLAG;
                        flag_wait     <= 5'd1;
                    end
                end
            end

            // ---------- 等元数据字(整帧结论) ----------
            ST_FLAG: begin
                if (is_meta) begin
                    mac_crc_bad_r <= fifo_rd_data[7];
                    of_r       <= fifo_rd_data[0];
                    of_evt     <= fifo_rd_data[0];
                    state         <= ST_PUSH;
                    push_count    <= 3'd0;
                end
                else if (fifo_rd_vld || (flag_wait == 5'd31)) begin
                    // 元数据没来却先来了新帧的字节, 或者超过有界等待:
                    // 沿用原实现"等不到结论就按坏帧"的同一口径。
                    mac_crc_bad_r <= 1'b1;
                    of_r          <= 1'b0;
                    state         <= ST_PUSH;
                    push_count    <= 3'd0;
                end
                else begin
                    flag_wait <= flag_wait + 5'd1;
                end
            end

            // ---------- 6 个字依次入记录 FIFO ----------
            default: begin
                if (!push_ready) begin
                    push_dropped <= 1'b1;
                    busy_dropped <= newer_frame_pend;
                    state        <= ST_IDLE;
                end
                else begin
                    if (push_count < 3'd6) begin
                        push_req  <= 1'b1;
                        push_count<= push_count + 3'd1;
                        case (push_count)
                            3'd0: push_word <= epoch_r;
                            3'd1: push_word <= seq_r;
                            3'd2: push_word <= first_r[31:0];
                            3'd3: push_word <= first_r[63:32];
                            3'd4: push_word <= {flags_r, count_r};
                            default: push_word <= {8'd0, mac_crc_bad_r, app_crc_bad_r,
                                                  hdr_bad_r, etype_bad_r, da_bad_r,
                                                  (len_err_r | of_r), content_bad_r,
                                                  type_r, byte_len};
                        endcase
                    end
                    else begin
                        busy_dropped <= newer_frame_pend;
                        state        <= ST_IDLE;
                    end
                end
            end
            endcase
        end
    end
endmodule
