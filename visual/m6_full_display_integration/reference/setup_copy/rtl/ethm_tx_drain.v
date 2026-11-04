`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// TX 排空机(tx_clk_125 域): 把字节 FIFO 里的应用字节按 TEMAC 客户端流吐出去。
//
// 为什么单独有这一级: 发包机搬到 25MHz 后, TEMAC 的 tx_data/tx_data_en/tx_rdy
// 握手仍在 125MHz, 两者之间必须有个"随时在等 rdys"的小状态机, 同时把 FIFO 的
// 1 拍读延迟记账清楚。
//
// 硬不变量(违反就会造出线上假错帧, 必须让后人一眼看到):
//   1) 帧内不得有空隙: tx_data_en 只有在"帧内最后一个字(kind=2'b01)已被 MAC 取走"
//      之后才允许落低。实现: tx_data_en 是 (state==RUN) && 槽里有字节 的组合,
//      帧内每拍取走一个字节就在同一拍发起下一个读请求, 于是新字节恰好在下一拍
//      出现在 rd_data 上 —— 读延迟被消费动作吸收, 不产生空隙。
//   2) 不在 tx_rdy 为低时起帧: 起帧判定在 IDLE 做, 只有 app_tx_rdy=1 才进 RUN;
//      首字节此时仍留在 FIFO 槽里(不先发 rd_en), 下一拍由 RUN 呈现, 所以
//      tx_data_en 的上升时刻与 051 发包机原来 `pkt_pending && tx_rdy` 一致。
//   3) 只在真的呈现有效字节时才置 tx_data_en: rd_data 是寄存输出, 所以呈现条件
//      用 rd_vld(与 rd_data 同拍新鲜)而不是 !rd_empty —— 后者会把陈旧字重发一次,
//      也会在取字失败时把同一个字节当成两个发出去。
//   4) 帧内断供(FIFO 一时没有字节)=> 该帧已经坏了, 必须显式报 underrun 脉冲,
//      并进入 FLUSH 把这一帧剩下的字节丢到 kind=2'b01 为止, 重新对齐帧边界。
//      不 flush 就会把残帧的中间字节当新帧首发, 后续每一帧都错位(静默连环错)。
//      FLUSH 带 2048 拍上限: 一帧最多 306 字, 超限说明流里根本没有帧尾标记,
//      此时强行回 IDLE, 免得发送侧被永久卡死。
//   5) 整帧装好了才起帧(最关键的一条): 生产者在 app_clk 25MHz 上每拍写一个字节
//      (40ns/字节), 消费者在 tx_clk 125MHz 上每拍最多吐一个字节(8ns/字节), 也就是说
//      排空机一开局就会把发包机甩在身后, 帧内必然断供 —— 只要 tx_rdy 长期为高,
//      "边写边发"必然把帧打断。所以 IDLE 起帧前必须等到整帧(306 字)都已落进 FIFO
//      (用 rd_usedw 判, 它是同步过来的写指针差, 只会偏小而不会偏大, 因此这个门是
//      保守的)。代价: 每帧多约 12.2us 的排队延迟(306 拍 x 40ns), 相对 2.67ms 的
//      包周期和 PCM 口径完全可以接受, 换来的是"帧内绝无断供"这条可证的不变量。
//      underrun 因此只应出现在真出错(生产者被饿/指针被复位)的时候, 一旦上板看到
//      它非 0, 就说明上面这条前提被破坏了。
//------------------------------------------------------------------------------
module ethm_tx_drain #(
    parameter integer FRAME_BYTES = 306   // 一帧应用字节数(051: 306)
)(
    input  wire        clk,             // tx_clk 125MHz
    input  wire        rst,             // tx_rst

    // 字节 FIFO 读侧(app_clk 写, tx_clk 读)
    input  wire [9:0]  fifo_rd_data,
    input  wire [1:0]  fifo_rd_kind,
    input  wire        fifo_rd_vld,
    input  wire        fifo_rd_last,
    input  wire        fifo_rd_empty,
    input  wire [9:0]  fifo_rd_usedw,   // 还没被取走的字数(整帧齐了才起帧)
    output wire        fifo_rd_en,      // = 本拍消费 fifo_rd_data

    // TEMAC 客户端发送流
    input  wire        app_tx_rdy,
    output wire [7:0]  tx_data,
    output wire        tx_data_en,

    output reg         underrun         // 脉冲: 帧内断供, 该帧已损坏
);
    localparam [1:0] KIND_DATA = 2'b00;
    localparam [1:0] KIND_LAST = 2'b01;
    localparam [1:0] KIND_META = 2'b10;

    localparam [1:0] DR_IDLE  = 2'd0;   // 等帧首(要求 tx_rdy 已高)
    localparam [1:0] DR_RUN   = 2'd1;   // 帧内逐字节, 不许留空隙
    localparam [1:0] DR_FLUSH = 2'd2;   // 坏帧残字丢弃到 kind=LAST 为止

    localparam [11:0] FLUSH_LIMIT = 12'd2048;

    reg [1:0]  state;
    reg [11:0] flush_cnt;

    // 槽里是一个可以呈现给 MAC 的字节(元数据字不属于 TX 流, 出现即为异常)
    wire byte_ok   = fifo_rd_vld && (fifo_rd_kind != KIND_META);
    wire meta_slot = fifo_rd_vld && (fifo_rd_kind == KIND_META);

    // ---------- 组合译码(事件全部在这里, 时序块只做一次赋值) ----------
    wire present     = (state == DR_RUN) && byte_ok;      // 本拍向 MAC 呈现字节
    wire mac_take    = present && app_tx_rdy;             // 本拍被 MAC 取走
    wire frame_end   = mac_take && fifo_rd_last;          // 帧尾字节被取走
    wire frame_ruin  = (state == DR_RUN) && !byte_ok;     // 帧内却没有字节 => 断供
    // 整帧齐了吗: usedw 是同步过来的写指针与本地读指针之差, 只会偏小而不会偏大,
    // 所以这个门是保守的。比较放在 32 位常量域里做(FRAME_BYTES 是 integer 参数)。
    wire ready_all   = ({22'd0, fifo_rd_usedw} >= (FRAME_BYTES - 1));
    // 起帧: 首字节仍留在槽里(本拍不发 rd_en), 下一拍由 RUN 呈现, 于是 tx_data_en
    // 的上升时刻与 051 发包机原来 `pkt_pending && tx_rdy` 的起帧时序完全一致。
    wire idle_start  = (state == DR_IDLE) && byte_ok && app_tx_rdy && ready_all;
    // IDLE 只在"槽空要取字"或"槽里是不该出现的元数据字要丢掉"时发请求; 字一到
    // 条件自动收回, 否则会把刚到手的首字节又吃掉(取字请求必须组合依赖 rd_vld)。
    wire idle_need   = (state == DR_IDLE) && (!fifo_rd_vld || meta_slot);
    wire flush_take  = (state == DR_FLUSH) && fifo_rd_vld;
    wire flush_end   = flush_take && fifo_rd_last;        // 重新找到帧边界
    wire flush_abend = (state == DR_FLUSH) && (flush_cnt >= FLUSH_LIMIT);

    // 读请求只在"本拍真的处理掉槽里那个字"时发出, 于是 1 拍读延迟恰好被消费吸收
    assign fifo_rd_en = mac_take || idle_need || (state == DR_FLUSH);

    assign tx_data    = fifo_rd_data[7:0];
    assign tx_data_en = present;

    always @(posedge clk) begin
        if (rst) begin
            state    <= DR_IDLE;
            flush_cnt<= 12'd0;
            underrun <= 1'b0;
        end
        else begin
            underrun <= frame_ruin;

            case (state)
            DR_IDLE: begin
                if (idle_start)
                    state <= DR_RUN;      // 首字节留在槽里, 下一拍才呈现
            end

            DR_RUN: begin
                if (frame_ruin) begin
                    state     <= DR_FLUSH;
                    flush_cnt <= 12'd0;
                end
                else if (frame_end)
                    state <= DR_IDLE;     // tx_data_en 从此才允许落低
            end

            // ---------- 坏帧残字: 丢到帧尾标记为止 ----------
            default: begin
                if (flush_end || flush_abend)
                    state <= DR_IDLE;
                else
                    flush_cnt <= flush_cnt + 12'd1;
            end
            endcase
        end
    end
endmodule
