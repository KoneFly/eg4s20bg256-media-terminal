`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// RX 捕获机(rx_clk_use 125MHz 域): 把 TEMAC 客户端字节流原样搬进字节 FIFO,
// 并在帧尾追加一个"字结论"元数据, 让帧边界与 MAC CRC 结论跟着数据一起跨到 app 域。
//
// 为什么这一级必须留在 125MHz: TEMAC 的 rx_data_vld 在帧内每拍给一个字节, 掉拍
// 就是丢字节, 事后补不回来; 而收包机的解析+判定根本不需要 8ns 节拍(线上平均只有
// 114,750 字节/s)。所以"贴标签"留在快侧, "理解字节"搬到慢侧。
//
// 写进 FIFO 的字:
//   kind=2'b00 帧内数据字节
//   kind=2'b01 帧内最后一个数据字节 —— 只有到 dv 落低那一拍才知道谁是帧尾,
//            所以每个字节都比收讫晚一拍写出口, 这是打帧尾标记必须付的一拍代价。
//   kind=2'b10 元数据, 每帧恰好一个字, data[7:0] = {mac_crc_bad, 6'b0, truncated}
//            顺序不变量: 元数据一定排在该帧 kind=01 之后、下一帧任何字节之前,
//            所以收包机读到 kind=01 就已经知道"数据段结束", 读到一个 kind=10
//            就已经拿到整帧结论, 不需要再等 MAC 的边带信号跨过来。
//
// 帧结论(把原 ethm_rx_pack 的 ST_FLAG 语义整段搬来, 口径不变):
//   dv 落低 => 等 rx_correct_frame / rx_error_frame, 最多等 FLAG_LIMIT(31) 拍;
//   correct -> mac_crc_bad=0, error -> 1, 超时 -> 1(当作坏帧)。
//   等待期间 dv 又变高(帧背靠背, 上一条结论还没到)时, 立刻按"超时=坏帧"补写元数据:
//   元数据不能插到新帧字节后面去。这就是原来那条"不把帧中字节误当帧首"的重挂规则
//   在新结构里的等价写法 —— 帧边界改由 kind 标记交付, 收包机再慢也只是让字节在
//   FIFO 里排队, 绝不会认错帧首。
//
// 不许静默丢字: 任何"想写但 FIFO 满", 以及"一字节深流水位被占住导致新字节无处
// 安放", 都算溢出: 既出 fifo_overflow 脉冲(交统计域累计), 也把本帧元数据的
// truncated 位置 1, 让收包机把这一帧按长度错处理。512 深已经为整帧突发留了余量,
// 真走到这条分支一定是结构性 bug, 必须看得见(VERIFICATION_CONTRACT: 溢出为 0
// 是验收项, 混进 CRC 错里就会污染判据)。
//------------------------------------------------------------------------------
module ethm_rx_capture (
    input  wire        clk,               // rx_clk_use
    input  wire        rst,               // rx_rst

    input  wire [7:0]  rx_data,
    input  wire        rx_data_vld,
    input  wire        rx_correct_frame,
    input  wire        rx_error_frame,

    input  wire        fifo_wr_full,
    output wire        fifo_wr_en,
    output wire [9:0]  fifo_wr_data,
    output reg         fifo_overflow      // 脉冲: 本拍有字被满挡下(不得静默)
);
    localparam [1:0] KIND_DATA  = 2'b00;
    localparam [1:0] KIND_LAST  = 2'b01;
    localparam [1:0] KIND_META  = 2'b10;

    localparam [1:0] CAP_CAPT   = 2'd0;   // 帧内: 逐字节写入
    localparam [1:0] CAP_FLAG   = 2'd1;   // dv 已落低: 等 TEMAC 整帧结论
    localparam [4:0] FLAG_LIMIT = 5'd31;  // 与原来收包机的等标志上限一致

    reg        dv_d;
    reg        hold_vld;      // 一字节深流水: 本拍可以写出的字节
    reg        hold_last;     // 该字节已确认是帧尾(被挡没写出去时才置位)
    reg [7:0]  hold_byte;
    reg [1:0]  cstate;
    reg [4:0]  flag_wait;
    reg        byte_of_r;   // 本帧已经有字节被丢(新帧开始即清零)

    // ---------------- 帧结论事件译码 ----------------
    wire in_flag    = rx_correct_frame | rx_error_frame;
    wire flag_good  = (cstate == CAP_FLAG) && rx_correct_frame;
    wire flag_err   = (cstate == CAP_FLAG) && rx_error_frame;
    wire flag_tmo   = (cstate == CAP_FLAG) && (!in_flag) && (flag_wait == FLAG_LIMIT);
    // 重挂: 结论还没到, 新帧的字节已经到了 —— 只能现在就补元数据
    wire flag_rearm = (cstate == CAP_FLAG) && (!in_flag) && (flag_wait != FLAG_LIMIT)
                      && rx_data_vld;
    wire meta_evt   = flag_good | flag_err | flag_tmo | flag_rearm;
    wire crc_bad_w  = flag_good ? 1'b0 : 1'b1;

    // ---------------- 写口仲裁(元数据优先, 它必须排在下一帧字节之前) ----------------
    wire       byte_wr   = hold_vld && (!meta_evt) && (!fifo_wr_full);
    // 流水位被元数据或满占住, 这一拍又恰好有新字节进来 => 这个字节真的丢了
    wire       byte_lost = rx_data_vld && hold_vld && (!byte_wr);
    wire       meta_lost = meta_evt && fifo_wr_full;
    wire [1:0] byte_kind = (hold_last || (!rx_data_vld)) ? KIND_LAST : KIND_DATA;
    wire [9:0] byte_word = { byte_kind, hold_byte };
    wire [9:0] meta_word = { KIND_META, crc_bad_w, 6'd0, (byte_of_r | byte_lost) };

    assign fifo_wr_en   = byte_wr || (meta_evt && !fifo_wr_full);
    assign fifo_wr_data = byte_wr ? byte_word : meta_word;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dv_d          <= 1'b0;
            hold_vld      <= 1'b0;
            hold_last     <= 1'b0;
            hold_byte     <= 8'd0;
            cstate        <= CAP_CAPT;
            flag_wait     <= 5'd0;
            byte_of_r     <= 1'b0;
            fifo_overflow <= 1'b0;
        end
        else begin
            dv_d          <= rx_data_vld;
            fifo_overflow <= byte_lost || meta_lost;

            // ---------- 一字节深流水: 被挡时原地保持, 只补"帧尾"标记 ----------
            if (hold_vld && !byte_wr) begin
                hold_last <= hold_last || (!rx_data_vld);
            end
            else begin
                hold_vld  <= rx_data_vld;
                hold_last <= 1'b0;
                hold_byte <= rx_data;
            end

            // ---------- 本帧丢字节粘住(新帧第一字节到达即清零) ----------
            if (byte_lost)
                    byte_of_r <= 1'b1;
            else if (!dv_d && rx_data_vld)
                    byte_of_r <= 1'b0;

            // ---------- 结论字被挡: 只出 fifo_overflow 脉冲并按本帧处理 ----------
            // 不做全局粘滞: 元数据字被挡一定同时有字节被挡(byte_of_r 已覆盖),
            // 而粘滞会把之后每一帧的 truncated 都点成 1, 把一次故障变成永久污染。
            // 这条路径的漏检兜底是收包机 ST_FLAG 的 31 拍有界等待(按坏帧计)。

            // ---------- 等整帧结论 ----------
            if (dv_d && !rx_data_vld) begin
                cstate    <= CAP_FLAG;
                flag_wait <= 5'd1;
            end
            else if (meta_evt) begin
                cstate    <= CAP_CAPT;
            end
            else if (cstate == CAP_FLAG) begin
                flag_wait <= flag_wait + 5'd1;
            end
        end
    end
endmodule
