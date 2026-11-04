`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// 统计与观测域(app_clk 25MHz)。
// 消费同域的 6 字帧记录 -> epoch/序号/样本位置连续性判定 -> 分类计数 +
// 首错条件快照 + 500ms 离线判定与恢复时长 + 记录 FIFO 最大占用 + 运行时长,
// 驱动 4 位状态 LED 与 16 位 dled 读数页, 并产出本板发送用 epoch。
//
// 本域原来跑在 tx_mac_clk 125MHz, 灰码跨域还原(32bit)那 5 级移位异或曾经是把
// 发送域 Fmax 压到 77.3MHz 的最差路径。现在收包机、发包机、统计全在 app_clk,
// 记录 FIFO 与这些事件都是同域单拍脉冲, 直接计数即可, 灰码链整段删除。
//
// 分类口径(VERIFICATION_CONTRACT: 报告要区分 CRC 错/序号缺口/溢出/旧 epoch/断链,
// 不得只报"灯亮", 也不得把不同病因混成一个数):
//   bit0 mac_crc  TEMAC 帧校验失败          bit1 app_crc  应用层 CRC32 不符
//   bit2 hdr      magic/version/长度/reserved 不符
//   bit3 etype    EtherType 非 0x88B5       bit4 len      帧长非 306 字节
//   bit5 da       目的 MAC 不符             bit6 content   载荷图形不符
//   bit7 type     type 非本角色期望值        bit8 epoch_sw  会话切换
//   bit9 old_epoch旧会话数据(丢弃不补样)     bit10 gap      序号缺口
//   bit11 next_first 样本位置不衔接          bit12 tx_overrun 发包节拍堆积
//   bit13 rx_drop  接收侧丢弃(记录丢弃/溢出)  bit14 offline  500ms 判离线
//   bit15 link     物理链路状态变化(保留)
//
// 写法约定: 每个寄存器在本块内只有一处时序赋值, 事件译码一律放组合逻辑, 避免
// "同一块内多分支赋同一寄存器" 时后赋值悄悄覆盖前赋值(LESSON-013 同类陷阱)。
//------------------------------------------------------------------------------
module ethm_stats #(
    parameter [31:0] DELIV_REV   = 32'h0520_0001,
    parameter [7:0]  EXPECT_TYPE = 8'd1
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        ms_tick,

    input  wire [31:0] rec_data,
    input  wire        rec_empty,
    input  wire [6:0]  rec_usedw,
    input  wire [9:0]  rxf_usedw,
    output wire        rec_rd_en,

    // 接收侧丢弃事件(全部是同域单拍脉冲, 直接累计)。原来是接收域灰码计数
    // 跨域还原, 现在统计与收包机同在 app_clk, 不再需要灰码。
    input  wire        rec_drop_evt,   // 记录装不下而整条丢弃
    input  wire        busy_drop_evt,  // 丢弃时下一帧已经在排队(口径同原 busy_dropped)
    input  wire        rec_of_evt,     // 记录 FIFO 写被满挡下
    input  wire        cap_of_evt,     // 字节 FIFO 溢出丢过字节(按帧上报)

    input  wire        tx_pacer_overrun,
    input  wire [15:0] tx_stall_max,
    input  wire [31:0] tx_frames,
    input  wire        tx_mac_fault,

    input  wire        rx_locked,
    input  wire        speed_1000,
    input  wire [3:0]  rxc_rate_code,
    input  wire        force_restart,
    input  wire        clear_sticky,
    input  wire [2:0]  page_sel,

    // ---- LINK_REPORT 6.1.1 R-b: 离线冲刷的落地回报(全部 app 域同域信号, 不跨域) ----
    // flush_done:   link_core 冲刷序列机释放那一拍给的一拍脉冲
    // flush_drop_n: 冲刷置起那拍锁存下来的 RX 字节 FIFO 占用 = 本次按设计丢弃的字节数
    //               (绝对不静默丢: 丢弃量必须能读)
    input  wire        flush_done,
    input  wire [9:0]  flush_drop_n,

    output wire        offline_evt,   // 离线判定那一拍(单拍, app 域内, 供 link_core 起冲刷)
    output wire        fft_ready,     // R-c: 连续样本 >=4096 且当前非离线

    output reg  [31:0] epoch,
    output reg  [15:0] dled_val,
    output reg  [3:0]  led
);
    wire link_ok_w = rx_locked && speed_1000 && (rxc_rate_code == 4'd3);

    localparam [26:0] OFF_LIMIT = 27'd500;
    localparam [31:0] FFT_MIN   = 32'd4096;   // 6.1.1 R-c: 连续样本门限
    localparam [8:0]  EXP_LEN   = 9'd306;

    // ---------------- 记录收集 ----------------
    // 记录 FIFO 读侧是寄存输出(rd_en 后一拍数据才有效), 因此取词与用词相差一拍:
    // 每拍最多发一个读请求, 下一拍按 slot 归档; word_last 是归档第 6 字那拍的
    // 组合判定, 所有分类译码只用已归档寄存器, 不用当拍的 rec_data。
    reg  [2:0]  slot;
    reg         busy_rd;
    reg  [31:0] r_epoch;
    reg  [31:0] r_seq;
    reg  [31:0] r_first_lo;
    reg  [31:0] r_first_hi;
    reg  [31:0] r_word5;

    wire        rd_take   = (!rec_empty) && (!busy_rd);
    reg         word_last_q;
    wire        word_last = word_last_q;
    assign      rec_rd_en = rd_take;

    wire [31:0] w_in       = r_word5;
    wire        v_mac_crc  = w_in[23];
    wire        v_app_crc  = w_in[22];
    wire        v_hdr      = w_in[21];
    wire        v_etype    = w_in[20];
    wire        v_da       = w_in[19];
    wire        v_len      = w_in[18];
    wire        v_content  = w_in[17];
    wire [7:0]  v_type     = w_in[16:9];
    wire [8:0]  v_bytelen  = w_in[8:0];

    // ---------------- 会话与计数寄存器 ----------------
    reg         have_peer;
    reg  [31:0] peer_epoch;
    reg  [31:0] peer_seq;
    reg  [63:0] next_first_exp;

    reg [31:0] c_frames_seen;  //synthesis keep
    reg [31:0] c_good;  //synthesis keep
    reg [31:0] c_mac_crc;  //synthesis keep
    reg [31:0] c_app_crc;  //synthesis keep
    reg [31:0] c_hdr;  //synthesis keep
    reg [31:0] c_etype;  //synthesis keep
    reg [31:0] c_len;  //synthesis keep
    reg [31:0] c_content;  //synthesis keep
    reg [31:0] c_type;  //synthesis keep
    reg [31:0] c_da;  //synthesis keep
    reg [31:0] c_old_epoch;  //synthesis keep
    reg [31:0] c_epoch_sw;  //synthesis keep
    reg [31:0] c_epoch_reuse;  //synthesis keep
    reg [31:0] c_dup_seq;  //synthesis keep
    reg [31:0] c_flush;  //synthesis keep
    reg [31:0] c_flush_drop;  //synthesis keep
    reg [31:0] c_tx_while_offline;  //synthesis keep
    reg [31:0] c_gap_pkts;  //synthesis keep
    reg [31:0] c_gap_samples;  //synthesis keep
    reg [31:0] c_next_first_err;  //synthesis keep
    reg [31:0] c_tx_overrun;  //synthesis keep
    reg [31:0] c_tx_retry;  //synthesis keep
    reg [31:0] c_rx_samples;  //synthesis keep
    reg [31:0] c_contig;  //synthesis keep
    reg [31:0] c_recover_ms;  //synthesis keep
    reg [31:0] c_offline_ms_max;  //synthesis keep
    reg [15:0] c_err_bits;  //synthesis keep
    reg [31:0] c_rx_drop;  //synthesis keep
    reg [6:0]  c_recfifo_max_used;  //synthesis keep
    reg [9:0]  c_rxfifo_max_used;  //synthesis keep
    reg [31:0] c_first_err_word;  //synthesis keep
    reg [31:0] c_first_err_seq;  //synthesis keep
    reg [31:0] c_first_err_epoch;  //synthesis keep
    reg        first_err_taken;

    reg [31:0] run_ms;
    reg [26:0] silent_ms;
    reg        offline_flag;
    reg [31:0] offline_start_ms;

    reg [31:0] free_cnt;
    reg [15:0] boot_entropy;
    reg        entropy_taken;
    reg [15:0] session_id;

    reg [31:0] tx_frames_prev;
    reg [31:0] deliv_rev_hold;  //synthesis keep
    reg [7:0]  hb_div;
    reg        hb_tgl;

    // ---------------- 本帧分类译码 ----------------
    wire [63:0] w_first   = {r_first_hi, r_first_lo};
    wire        proto_ok  = (!v_mac_crc) && (!v_app_crc) && (!v_hdr) && (!v_etype)
                         && (!v_da) && (!v_len) && (v_bytelen == EXP_LEN)
                         && (v_type == EXPECT_TYPE);
    wire        same_epoch = have_peer && (r_epoch == peer_epoch);
    wire        boot_change= have_peer && (r_epoch[31:16] != peer_epoch[31:16]);
    wire        sess_newer = have_peer && (r_epoch[31:16] == peer_epoch[31:16])
                                && (r_epoch[15:0] >  peer_epoch[15:0]);
    wire        sess_older = have_peer && (r_epoch[31:16] == peer_epoch[31:16])
                                && (r_epoch[15:0] <  peer_epoch[15:0]);
    wire [31:0] seq_ahead  = r_seq - peer_seq;
    // 序号关系分四类(6.1.1 R-a), 旧写法有两处会把验收数字读歪:
    //   1) "回退"和"前向巨跳"都塞进 wild_jump 一起点亮 bit11, 与"样本位置错"混读;
    //   2) seq_ahead==0(重复序号)落在 gap_counted 的 (seq_ahead != 1 && <=65535) 里,
    //      于是 c_gap_pkts 被加 (0 - 1) = 4294967295 —— 一笔重复帧就把缺口计数加爆。
    wire        seq_dup     = proto_ok && same_epoch && (seq_ahead == 32'd0);
    wire        gap_counted = proto_ok && same_epoch && (seq_ahead >= 32'd2)
                           && (seq_ahead <= 32'd65535);
    wire        seq_back    = proto_ok && same_epoch && (r_seq < peer_seq);
    wire        wild_jump   = proto_ok && same_epoch && (r_seq > peer_seq)
                           && (seq_ahead >  32'd65535);
    wire        first_ok    = (w_first == next_first_exp);

    wire        accept_sess = word_last && proto_ok && (!sess_older);
    wire        ev_good     = accept_sess && same_epoch && (seq_ahead == 32'd1)
                           && first_ok && (!v_content);
    wire        ev_content_err = accept_sess && same_epoch && (seq_ahead == 32'd1)
                           && first_ok && v_content;
    wire        ev_integrity = word_last && (v_mac_crc | v_app_crc | v_hdr | v_etype
                           | v_da | v_len | (v_bytelen != EXP_LEN)
                           | (v_type != EXPECT_TYPE));
    wire        word_epoch_sw  = word_last && proto_ok && (boot_change | sess_newer);
    wire        word_old_epoch = word_last && proto_ok && sess_older;
    wire        next_first_bad = accept_sess && same_epoch && (seq_ahead == 32'd1)
                              && (!first_ok);
    // 同域丢弃事件: 一拍里可能同时来好几个, 所以按个数累加而不是只加 1
    wire [3:0]  drop_n      = {3'd0, rec_drop_evt}  + {3'd0, busy_drop_evt}
                            + {3'd0, rec_of_evt}    + {3'd0, cap_of_evt};
    wire [31:0] drop_delta  = {28'd0, drop_n};
    wire        rx_drop_now = (drop_n != 4'd0);
    // 粘滞位图: 每类病因一个独立 bit, 显式与或, 不用条件表达式嵌套(优先级陷阱)
    wire [15:0] err_set =
          ({16{word_last && v_mac_crc}} & 16'h0001)
        | ({16{word_last && v_app_crc}} & 16'h0002)
        | ({16{word_last && v_hdr}}     & 16'h0004)
        | ({16{word_last && v_etype}}   & 16'h0008)
        | ({16{word_last && v_len}}     & 16'h0010)
        | ({16{word_last && v_da}}      & 16'h0020)
        | ({16{ev_content_err}}         & 16'h0040)
        | ({16{word_last && (v_type != EXPECT_TYPE)}} & 16'h0080)
        | ({16{word_epoch_sw}}          & 16'h0100)
        | ({16{word_old_epoch}}         & 16'h0200)
        | ({16{word_last && gap_counted}} & 16'h0400)
        | ({16{word_last && (next_first_bad || wild_jump || seq_back || seq_dup)}} & 16'h0800)
        | ({16{tx_pacer_overrun}}       & 16'h1000)
        | ({16{rx_drop_now}}            & 16'h2000)
        | ({16{ms_tick && offline_flag}}& 16'h4000)
        | ({16{tx_mac_fault}}           & 16'h8000);

    wire        silent_clear = accept_sess;
    wire        offline_next = silent_clear ? 1'b0
                               : (offline_flag || (ms_tick && (silent_ms >= OFF_LIMIT)));
    wire        recover_evt  = offline_flag && (!offline_next);
    wire [31:0] recover_ms_calc = run_ms - offline_start_ms;
    // 离线判定的那一拍: 与置起 offline_flag 用的是同一个条件, 旗标起来后自然落回 0,
    // 所以它是恰好一拍的应用域脉冲(不存在"单拍脉冲跨域被漏"的问题)。
    assign offline_evt = ms_tick && (silent_ms >= OFF_LIMIT) && (!offline_flag);
    // R-c: 交付给下游 FFT 的"可用"标志。离线期间必为 0(重锚定后要从头攒 4096 样本)。
    assign fft_ready   = (c_contig >= FFT_MIN) && (!offline_flag);

    always @(posedge clk) begin
        if (rst) begin
            slot             <= 3'd0;
            busy_rd          <= 1'b0;
            word_last_q      <= 1'b0;
            r_word5          <= 32'd0;
            r_epoch          <= 32'd0;
            r_seq            <= 32'd0;
            r_first_lo       <= 32'd0;
            r_first_hi       <= 32'd0;
            have_peer        <= 1'b0;
            peer_epoch       <= 32'd0;
            peer_seq         <= 32'd0;
            next_first_exp   <= 64'd0;
            deliv_rev_hold   <= DELIV_REV;
            c_frames_seen    <= 32'd0;
            c_good           <= 32'd0;
            c_mac_crc        <= 32'd0;
            c_app_crc        <= 32'd0;
            c_hdr            <= 32'd0;
            c_etype          <= 32'd0;
            c_len            <= 32'd0;
            c_content        <= 32'd0;
            c_type           <= 32'd0;
            c_da             <= 32'd0;
            c_old_epoch      <= 32'd0;
            c_epoch_sw       <= 32'd0;
            c_epoch_reuse    <= 32'd0;
            c_dup_seq        <= 32'd0;
            c_flush          <= 32'd0;
            c_flush_drop     <= 32'd0;
            c_tx_while_offline <= 32'd0;
            tx_frames_prev   <= 32'd0;
            c_gap_pkts       <= 32'd0;
            c_gap_samples    <= 32'd0;
            c_next_first_err <= 32'd0;
            c_tx_overrun     <= 32'd0;
            c_tx_retry       <= 32'd0;
            c_rx_samples     <= 32'd0;
            c_contig         <= 32'd0;
            c_recover_ms     <= 32'd0;
            c_offline_ms_max <= 32'd0;
            c_err_bits       <= 16'd0;
            c_rx_drop        <= 32'd0;
            c_recfifo_max_used <= 7'd0;
            c_rxfifo_max_used  <= 10'd0;
            c_first_err_word <= 32'd0;
            c_first_err_seq  <= 32'd0;
            c_first_err_epoch<= 32'd0;
            first_err_taken  <= 1'b0;
            run_ms           <= 32'd0;
            silent_ms        <= OFF_LIMIT;
            offline_flag     <= 1'b1;
            offline_start_ms <= 32'd0;
            free_cnt         <= 32'd0;
            boot_entropy     <= 16'd0;
            entropy_taken    <= 1'b0;
            session_id       <= 16'd1;
            epoch            <= {16'h52ED, 16'd1};
            hb_div           <= 8'd0;
            hb_tgl           <= 1'b0;
            led              <= 4'b0001;
            dled_val         <= 16'd0;
        end
        else begin
            // ---------- 接收记录字归档 ----------
            word_last_q <= busy_rd && (slot == 3'd5);
            if (rd_take) begin
                busy_rd <= 1'b1;
            end
            else if (busy_rd) begin
                busy_rd <= 1'b0;
                case (slot)
                    3'd0:    r_epoch       <= rec_data;
                    3'd1:    r_seq         <= rec_data;
                    3'd2:    r_first_lo    <= rec_data;
                    3'd3:    r_first_hi    <= rec_data;
                    3'd5:    r_word5       <= rec_data;
                    default: ;
                endcase
                slot <= (slot == 3'd5) ? 3'd0 : (slot + 3'd1);
            end

            // ---------- 分类计数 ----------
            if (word_last)          c_frames_seen <= c_frames_seen + 32'd1;
            // R12: 这些 v_* 是**电平**(来自锁存的记录字 r_word5), 不与 word_last 相与
            // 就会"一条错帧 -> 每拍加一次", 直到下一条记录把它覆盖为止。协议台实测:
            // 一条截断帧 c_len=192、一条旧会话帧 c_old_epoch=398、重复序号 431 拍
            // => c_gap_pkts 累加 431 次 (0-1) 读成 -431。判据"计数为 0"仍成立
            // (没错就不加), 但任何一条错帧就让严重度/速率读数彻底失真。
            if (word_last && v_mac_crc)  c_mac_crc <= c_mac_crc + 32'd1;
            if (word_last && v_app_crc)  c_app_crc <= c_app_crc + 32'd1;
            if (word_last && v_hdr)      c_hdr     <= c_hdr + 32'd1;
            if (word_last && v_etype)    c_etype   <= c_etype + 32'd1;
            if (word_last && v_da)       c_da      <= c_da + 32'd1;
            if (word_last && v_len)      c_len     <= c_len + 32'd1;
            if (word_last && (v_type != EXPECT_TYPE)) c_type <= c_type + 32'd1;
            if (ev_content_err)     c_content     <= c_content + 32'd1;
            if (ev_good) begin
                c_good       <= c_good + 32'd1;
                c_rx_samples <= c_rx_samples + 32'd128;
            end
            if (word_last && proto_ok && (boot_change || sess_newer))
                                  c_epoch_sw      <= c_epoch_sw + 32'd1;
            // 语义保持"只要学到的是旧会话就计", 只补每帧一次的门(不额外加 proto_ok 条件)
            if (word_last && sess_older)  c_old_epoch <= c_old_epoch + 32'd1;
            // R-a: 序号回退单列(对端复位后 epoch 恰好回到同一初值的情形)
            if (word_last && seq_back) c_epoch_reuse <= c_epoch_reuse + 32'd1;
            if (word_last && seq_dup)  c_dup_seq     <= c_dup_seq + 32'd1;
            // R-b: 冲刷落地回报
            if (flush_done) begin
                c_flush      <= c_flush + 32'd1;
                c_flush_drop <= c_flush_drop + {22'd0, flush_drop_n};
            end
            // 本轮不冲刷 TX 侧(6.1.1 R-b 第 3 条的取舍), 改为把"离线期间还在发包"计数可见
            tx_frames_prev <= tx_frames;
            if (offline_flag && (tx_frames != tx_frames_prev))
                c_tx_while_offline <= c_tx_while_offline + 32'd1;
            if (word_last && gap_counted) begin
                c_gap_pkts    <= c_gap_pkts + (seq_ahead - 32'd1);
                c_gap_samples <= c_gap_samples + ((seq_ahead - 32'd1) << 7);
            end
            if ((word_last && wild_jump) || (accept_sess && same_epoch && (seq_ahead == 32'd1)
                              && (!first_ok)))
                                  c_next_first_err<= c_next_first_err + 32'd1;
            if (tx_pacer_overrun) c_tx_overrun    <= c_tx_overrun + 32'd1;
            if (tx_mac_fault)     c_tx_retry      <= c_tx_retry + 32'd1;
            if (rx_drop_now)      c_rx_drop       <= c_rx_drop + drop_delta;
            if (rec_usedw > c_recfifo_max_used) c_recfifo_max_used <= rec_usedw;
            // RX 字节 FIFO 才是线速积压的真值(512 深 => 必须 10 bit),
            // 记录 FIFO 的 7 bit 水位代表不了它, 两者分别登记。
            if (rxf_usedw > c_rxfifo_max_used) c_rxfifo_max_used <= rxf_usedw;

            // ---------- 会话状态与连续性 ----------
            // 离线判定一到就作废本会话锚定并清零连续窗(裁定: 排除旧缓存 + 恢复后重新确认会话),
            // 冲刷序列机随后只负责把"字还在 FIFO 里"这件事也清干净。
            if (offline_evt) begin
                have_peer <= 1'b0;
                c_contig  <= 32'd0;
            end
            else begin
                if (accept_sess) begin
                    have_peer      <= 1'b1;
                    peer_epoch     <= r_epoch;
                    peer_seq       <= r_seq;
                    next_first_exp <= w_first + 64'd128;
                end
                if (ev_good)          c_contig <= c_contig + 32'd128;
                else if (accept_sess) c_contig <= 32'd128;
                else if (word_last)   c_contig <= 32'd0;
            end

            // ---------- epoch 熵源与会话重启 ----------
            free_cnt <= free_cnt + 32'd1;
            if (!entropy_taken && rx_locked) begin
                entropy_taken <= 1'b1;
                boot_entropy  <= free_cnt[23:8];
                session_id    <= session_id + 16'd1;
                have_peer     <= 1'b0;
            end
            else if (force_restart) begin
                session_id    <= session_id + 16'd1;
                have_peer     <= 1'b0;
            end
            epoch <= {boot_entropy, session_id};

            // ---------- 运行时长(ms_tick 由 ethm_link_core 统一产生) ----------
            if (ms_tick)
                run_ms <= run_ms + 32'd1;
            if (silent_clear)        silent_ms <= 27'd0;
            else if (ms_tick && (silent_ms < OFF_LIMIT))
                                     silent_ms <= silent_ms + 27'd1;
            offline_flag <= offline_next;
            if (!offline_flag && ms_tick && (silent_ms >= OFF_LIMIT))
                offline_start_ms <= run_ms;
            if (recover_evt) begin
                c_recover_ms <= recover_ms_calc;
                if (recover_ms_calc > c_offline_ms_max)
                    c_offline_ms_max <= recover_ms_calc;
            end

            // ---------- 粘滞错误位与首错条件 ----------
            if (clear_sticky)       c_err_bits <= 16'd0;
            else                    c_err_bits <= c_err_bits | err_set;
            if ((ev_integrity || ev_content_err || gap_counted || sess_older
                 || rx_drop_now) && (!first_err_taken || clear_sticky)) begin
                first_err_taken   <= 1'b1;
                c_first_err_word  <= w_in;
                c_first_err_seq   <= r_seq;
                c_first_err_epoch <= r_epoch;
            end

            // ---------- 链路 / LED ----------
            if (ms_tick) begin
                if (!offline_flag && (hb_div < 8'd9)) begin
                    hb_div <= hb_div + 8'd1;
                end
                else begin
                    hb_div <= 8'd0;
                    hb_tgl <= ~hb_tgl;
                end
            end
            led <= {offline_flag, (|c_err_bits), (offline_flag ? 1'b0 : hb_tgl),
                    link_ok_w};

            // ---------- dled 读数页(sw[3:1] 选择, 见 LINK_REPORT §读数表) ----------
            case (page_sel)
                3'd0:    dled_val <= c_good[15:0];
                3'd1:    dled_val <= c_good[31:16];
                3'd2:    dled_val <= c_frames_seen[15:0];
                3'd3:    dled_val <= run_ms[15:0];
                3'd4:    dled_val <= c_err_bits;
                3'd5:    dled_val <= {6'd0, c_rxfifo_max_used};
                3'd6:    dled_val <= c_contig[15:0];
                default: dled_val <= {deliv_rev_hold[3:0], tx_frames[11:0]};
            endcase
        end
    end
endmodule
