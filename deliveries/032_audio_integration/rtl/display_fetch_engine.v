`timescale 1ns / 1ps
// ============================================================================
// display_fetch_engine — VS 触发的帧缓冲连续读出引擎 (ctrl 域 50MHz)
//
// 职责: frame_write_done 后被武装; 每次 frame_start_pulse(VS 下降沿经 CDC)
// 从 (0,0) 到 (W-1,H-1) 行主序把整帧 307200 像素经显示读端口取出并压入
// 异步 FIFO 写侧, 压完回到等待态等下一次触发.
//
// 读请求协议(单拍脉冲, 与帧缓冲实际响应语义匹配):
//   帧缓冲显示读端口的命中响应按"呈现周期"产生(hit_pend <= display_req &&
//   lb_hit 每拍采样), 请求保持多拍会产生重复响应; 故每个读请求以恰好一拍
//   的 display_req 脉冲发出(帧缓冲请求捕获逻辑在首拍入队/命中), 随后
//   display_req=0 等待该请求的 display_valid(唯一响应), 响应后推进坐标.
//   请求-响应严格 1:1, 按请求顺序返回.
//
// 读出节奏(块节奏流水, 见 doc/spec/behavior_spec.md 推导):
//   行缓冲以 8 字(16 像素)为一块: 块首像素行缓冲未命中(单拍脉冲入队,
//   SDRAM 突发约 9 拍后响应); 块首响应到达后, 块内剩余 15 像素全部命中
//   行缓冲(响应固定滞后 2 拍的流水线), 以每拍 1 个请求的节奏连续发出,
//   每拍捕获一个响应写入 FIFO. 单块 27 拍 → 0.593 像素/拍 ≈ 29.6 Mpx/s,
//   高于 pixel 域 25.2 Mpx/s 的显示消耗率, 是"FIFO 永不空"的前提.
//
// almost_full 节流: 发出任何读请求前要求 !fifo_almost_full; 节流期间
// display_req 保持 0 且坐标不变(当前像素请求未发出); 已发出请求的响应
// (在途至多 3 个)必须捕获, 不丢弃. 顶层以 AFULL_MARGIN=36 例化 FIFO,
// 保证在途响应写入后水位仍 ≤ 992(契约水位).
//
// 帧对齐闭环: 每帧 FIFO 恰好排空(填充率>消耗率时由 almost_full 节流自动
// 跟随消耗), FIFO 空后 pixel 域清除预取标志, 下一次 VS 重新触发预填,
// 屏上位置 (x,y) 恒等于图案 (x,y).
// ============================================================================
module display_fetch_engine #(
    parameter integer FRAME_WIDTH  = 640,
    parameter integer FRAME_HEIGHT = 480
)(
    input  wire        clk,               // ctrl_clk 50MHz 0°
    input  wire        rst_n,
    input  wire        frame_write_done,  // 帧缓冲单拍脉冲(ctrl 域)
    input  wire        frame_start_pulse, // VS下降沿经CDC后的ctrl域单拍脉冲
    // 帧缓冲显示读接口(同步于 clk)
    output wire        display_req,
    output wire [10:0] display_x,
    output wire [9:0]  display_y,
    input  wire [15:0] display_data,
    input  wire        display_valid,
    // 异步FIFO写侧
    output wire        fifo_wr_en,
    output wire [15:0] fifo_wr_data,
    input  wire        fifo_almost_full,
    // 状态观测
    output wire        frame_latched,     // 已锁存 frame_write_done(用于LED)
    output wire        fetching           // 当前正在做一次帧获取
);

    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam [2:0] S_WAIT    = 3'd0,   // 等待触发
                     S_ISSUE   = 3'd1,   // 发出单拍读请求(块首)
                     S_REQWAIT = 3'd2,   // 等待块首响应(req=0)
                     S_STREAM  = 3'd3;   // 块内流水: 每拍1请求, 按序捕获

    reg [2:0]  state;
    reg        latched;
    reg [10:0] fx;
    reg [9:0]  fy;
    reg [4:0]  blk_issued;    // 本块已发出请求数 1..16
    reg [4:0]  blk_got;       // 本块已捕获响应数 0..16
    reg        last_issued;   // 帧末像素请求已发出(其响应到达即帧完成)

    // ---- 坐标推进(行主序) ----
    wire       cur_last = (fx == FRAME_WIDTH[10:0] - 11'd1) &&
                          (fy == FRAME_HEIGHT[9:0] - 10'd1);
    wire       col_last = (fx == FRAME_WIDTH[10:0] - 11'd1);
    wire [10:0] nx = col_last ? 11'd0 : fx + 11'd1;
    wire [9:0]  ny = col_last ? fy + 10'd1 : fy;

    wire in_issue   = (state == S_ISSUE);
    wire in_reqwait = (state == S_REQWAIT);
    wire in_stream  = (state == S_STREAM);
    // 块内流水段: 还有请求未发出且 FIFO 有节流空间才继续发出(每请求1拍)
    wire can_issue  = in_stream && (blk_issued < 5'd16) && !fifo_almost_full;

    assign display_req  = in_issue || can_issue;
    assign display_x    = fx;
    assign display_y    = fy;
    assign fifo_wr_en   = (in_reqwait || in_stream) && display_valid;
    assign fifo_wr_data = display_data;
    assign frame_latched = latched;
    assign fetching      = (state != S_WAIT);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_WAIT;
            latched     <= 1'b0;
            fx          <= 11'd0;
            fy          <= 10'd0;
            blk_issued  <= 5'd0;
            blk_got     <= 5'd0;
            last_issued <= 1'b0;
        end else begin
            if (frame_write_done)
                latched <= 1'b1;

            case (state)
            S_WAIT: begin
                // 只写一帧, 不重复武装: 触发需 frame_latched=1;
                // almost_full 期间不发出首个请求
                if (frame_start_pulse && latched && !fifo_almost_full) begin
                    fx          <= 11'd0;
                    fy          <= 10'd0;
                    blk_issued  <= 5'd1;   // 块首请求本拍发出
                    blk_got     <= 5'd0;
                    last_issued <= 1'b0;
                    state       <= S_ISSUE;
                end
            end

            S_ISSUE: begin
                // 单拍脉冲已发出, 转等待(块首必为行缓冲未命中, 响应经
                // SDRAM 突发返回, 约 9 拍)
                state <= S_REQWAIT;
            end

            S_REQWAIT: begin
                if (display_valid) begin
                    blk_got     <= 5'd1;
                    last_issued <= cur_last;
                    fx          <= nx;
                    fy          <= ny;
                    // 帧宽为 16 的倍数时块首不可能是帧末像素; 保留通用判断
                    state       <= cur_last ? S_WAIT : S_STREAM;
                end
            end

            S_STREAM: begin
                if (display_valid) begin
                    blk_got <= blk_got + 5'd1;
                end
                if (can_issue) begin
                    blk_issued  <= blk_issued + 5'd1;
                    last_issued <= cur_last;
                    fx          <= nx;
                    fy          <= ny;
                end
                if ((blk_got == 5'd15) && display_valid) begin
                    // 本块第16个响应到达, 块完成(坐标已指向下一块首)
                    blk_issued <= 5'd1;
                    blk_got    <= 5'd0;
                    if (last_issued || cur_last)
                        state <= S_WAIT;
                    else
                        state <= S_ISSUE;
                end
            end

            default: state <= S_WAIT;
            endcase
        end
    end

endmodule

