`timescale 1ns/1ps
// ============================================================================
// pcb_state_mem —— 状态表存储模型（T1 走线表 + T2 杂项表）。
//
// ★ 归属：冻结契约（INTERFACE_SPEC §Module Declaration）把状态表读口定义为
//   pcb_pixel_renderer 的**外部输入**（st_*_rdata 为 input），故存储不在渲染器
//   模块体内——本模型由 TB 装载黄金快照时实例化，S6b 集成时由主线按同一端口
//   提供 BRAM。布局与字段字节序以 reference/gen_vectors.cjs packState() 为准
//   （UPSTREAM_FACTS §3 声明其为唯一映射），见 INTERFACE_SPEC §状态表内存图。
//
//   T1 st_trace：128 深 × 128bit = 4 条 128×32 lane 存储（lane0..3 = wr_lane 0..3，
//                lane0 占记录 [31:0]）。写口按 wr_lane 单 lane 写，读口整 128bit 同步读。
//   T2 st_misc ：256 深 × 32bit，整字写。
//   两口独立时钟：读 = clk（像素域），写 = wr_clk（ctrl 域）——真双口 BRAM 语义，
//   读写不同地址（契约：写只在消隐期、像素域不读该行），不做冲突检测。
//   存储内容不属于复位域（复位不清存储，由写口决定）。
// ============================================================================
module pcb_state_mem (
    // 读口（clk 域，同步读，1 拍延迟，自由运行）
    input  wire         clk,
    input  wire [7:0]   st_trace_addr,
    output reg  [127:0] st_trace_rdata,
    input  wire [7:0]   st_misc_addr,
    output reg  [31:0]  st_misc_rdata,
    // 写口（wr_clk 域）
    input  wire         wr_clk,
    input  wire         wr_en,
    input  wire         wr_sel,      // 0 = st_trace，1 = st_misc
    input  wire [7:0]   wr_addr,
    input  wire [31:0]  wr_data,
    input  wire [1:0]   wr_lane      // st_trace 用：0..3 对应记录 [31:0]..[127:96]
);

    // ---- T1：4 条 lane 存储（各 128×32，可推断真双口 BRAM） ----
    reg [31:0] trace_l0 [0:127];
    reg [31:0] trace_l1 [0:127];
    reg [31:0] trace_l2 [0:127];
    reg [31:0] trace_l3 [0:127];

    always @(posedge wr_clk) begin
        if (wr_en && !wr_sel) begin
            case (wr_lane)
                2'd0: trace_l0[wr_addr[6:0]] <= wr_data;
                2'd1: trace_l1[wr_addr[6:0]] <= wr_data;
                2'd2: trace_l2[wr_addr[6:0]] <= wr_data;
                2'd3: trace_l3[wr_addr[6:0]] <= wr_data;
            endcase
        end
    end

    always @(posedge clk) begin
        st_trace_rdata <= {trace_l3[st_trace_addr[6:0]],
                           trace_l2[st_trace_addr[6:0]],
                           trace_l1[st_trace_addr[6:0]],
                           trace_l0[st_trace_addr[6:0]]};
    end

    // ---- T2：256×32 ----
    reg [31:0] misc_mem [0:255];

    always @(posedge wr_clk) begin
        if (wr_en && wr_sel)
            misc_mem[wr_addr] <= wr_data;
    end

    always @(posedge clk) begin
        st_misc_rdata <= misc_mem[st_misc_addr];
    end

endmodule
