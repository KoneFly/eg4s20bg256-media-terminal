`timescale 1ns / 1ps
// ============================================================================
// line_supply — 显示读口供数平面 (task_043; ctrl 域)  [v2.1: P2b bank 直服务]
//
// v1(P1) = 组合直通 + 协议观测(1:1 在途/提交点排空/越界/最长无响应/等受理),
//          anim_v=0 且无残留时与 v1 逐拍一致 ⇒ 基线场景零回归。
// v2(P2b 首版) → v2.1(评审修正, 修正项均有单元台判据):
//   修1 en0 自应答: bank 模式内 en=0(边框/占位)请求不再转发 fb —— 一拍自应答
//       (sq_en=0 + 原标签)。v2 以 fq_en=1 转发会使 fe 用图像数据着色边框像素,
//       且 en0 受理不等 fq_rdy, fb 未就绪时转发请求会丢响应挂死。
//   修2 填充 x 序去 S 化: kind0(墙行)=偶数步进(320 字; 墙路径取数恒为 4 的
//       倍数, 覆盖充分), 其余(缩放行/miss 补填)=全宽 0..639。v2 按 hint S
//       游走, 尾预发/跨帧 S 漂移时行内留覆盖缺口(实测相邻 k 最差 221 列)
//       却整行标记 valid ⇒ 陈旧列像素错误。
//   修3 覆盖位命中守卫: bank 标签增 full 位; 偶步行只对 cq_full=0(墙路径)
//       命中, 缩放路径(cq_full=1)命中偶步行视为 miss 走全宽补填 —— 修
//       "墙/缩放行采样同一 (slot,y) 键"的覆盖洞; 入队/弹出去重同口径
//       (否则 miss 补填被去重跳过 ⇒ 永久 miss → BOUNCE_TO 旁路)。
//   修4 hint_en 与 anim_v 分离: anim_v=anim_vf(消费侧 bank 服务), hint_en=
//       anim_busy(允许 hint 入队与填充) —— 触发后首帧前(pending)即可经 fb
//       口预取; 端口仲裁 = 消费者(直通/转发)严格优先, 填充仅空闲拍推进。
//   修5 填充队列索引位宽 = clog2(QDEPTH)(v2 恒 [2:0], QDEPTH=16 时 >8 项
//       环回覆写未读项)。
//   [v2.3 板测修复 2026-09-26] 动画帧整屏花屏(竖条带+欠载暗带, 修复前
//       8AAD9F8C 位实测)两根因:
//   修A 填充替换窗口假命中(错数据): fill_start 时旧路的 {v,full,t} 仍可见,
//       消费者请求旧行 → 命中"正在被整行覆写"的路 → 读出新旧按列拼接数据
//       (填充按 x 序逐字写入) = 竖条带花屏。修复 = fill_start 拍同步
//       bank_v[way_sel] 清零 ⇒ 在填行对消费者视为 miss → 入队补填, 只慢不错。
//   修B 工作集溢出逐行抖动(欠载): 动画帧在途行集 = {A(r),A(r+1),A(r+2)预取,
//       B,C 墙对} ≈ 5, WAYS=3 + 盲循环替换 ⇒ 正要消费的行每显示行都被预取
//       挤出 → 逐行 miss(~684 拍/行)成串 → FIFO 整帧欠载。修复 = WAYS 3→4
//       (顶层参数) + 替换选择跳过消费者最近命中路(prot_way) —— 驻留集
//       {A(r),B,C,A(r+1)} 恒命中, A(r+2) 淘汰的恰是已消费完的 A(r)。
//   [v2.5 板测修复 2026-09-26 深夜] p3wall 探针仿真定性: fb 端口持续吞吐
//       ≈0.48 字/拍(fill 恒 ~633 行/帧饱和), v2.2.1 全墙全宽 hint 使每帧填充
//       需求 985k~1.1M 拍 > 帧预算 833k; 且消费者 miss 的补填排在 hint 队尾
//       (最深 16 行) ⇒ 单次 miss 停顿可达 BTO=4096 拍(gwait 实测 ≈4110),
//       停顿链把显示 FIFO 全帧抽干(occmin=0, 整帧 ~65% 零像素)。
//   修C miss 优先队列: 消费者 miss 的补填行入专用 2 项队列, 填充引擎严格
//       先服务 miss 再服务 hint 预取 —— miss 延迟从"队尾全部填完"(可达
//       4096+) 降为 ≤ 在填行余量 + 自身一行(~700~1400 拍)。去重口径: bank
//       已全宽覆盖 / 该行在填(full) / 已在 m 队列 ⇒ 不重复入队; m 满则退回
//       原 q 尾行为(防溢出, BOUNCE_TO 兜底不变)。墙行 kind 收敛为全偶步由
//       顶层 hint 游走器执行(v2.5 修①)。
//   修D [v2.9] 在填行空手等待: 修A 替换拍失效使"正在填充的行"对消费者可见
//       为 miss, 原路径对该行再发一次 kind1 全宽补填(860 拍)且落入缩放分区
//       逐出缩放行(实测每墙行必触发 → miss×2/行级联, FIFO 永久失血 —
//       v2.5~v2.8 四版分区/LEAD 方案全败的共同根因)。修复 = miss 时同 tag
//       行在填(kind 不论) ⇒ C_WAIT 空手等填完不重复入队; 填完即命中;
//       填完仍不满足覆盖(kind0 填 vs 缩放请求)才一次性补全宽升级。
//       配套: 入队护栏 e2 恢复 !q_full(v2.5 重构时丢失, 饱和环回覆写)。
//   * miss 等待超时(BOUNCE_TO)→旁路直通 fb(= v1 行为, 可控回退, 防死锁);
//   * 消费者严格单在途(cq_rdy 门控) ⇒ 应答按序(v1 已证 1:1 按序协议);
//   * G2 观测全保留 + bank 命中/未命中/旁路/填充行计数。
//
// 填充队列项 13b: {kind, slot[1:0], y[9:0]} (kind: 0=墙偶步 1=全宽)
// ============================================================================
module line_supply #(
    parameter integer LINE_PIX     = 640,
    parameter integer LINE_NUM     = 480,
    parameter integer WAYS         = 4,     // bank 路数(两显示行工作集=4)
    parameter integer BOUNCE_TO    = 4096,  // miss 等待超时→旁路(拍)
    parameter integer QDEPTH       = 32     // [E1 修复] 填充队列深度 16→32(行):
                                            //   首帧 rect 首行+墙行爆发需求瞬间填满
                                            //   16 深队列 ⇒ hw 被反压停推 ⇒ 预取落后
                                            //   ⇒ sm_uncovered。加深后 hw 不易停推。
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,     // 帧提交点(vs_start_pulse)
    // ---- [P2b] bank 模式与行需求 hint ----
    input  wire        anim_v,          // 1=消费侧 bank 服务模式(A 类动画帧)
    input  wire        hint_en,         // 1=允许 hint 入队与 bank 填充(anim_busy)
    input  wire        hint_v,          // 本拍 hint 有效(游走器每拍至多 1 行)
    output wire        hint_rdy,        // [A3] 本拍可接收 hint(valid/ready 握手; q 满=0 反压)
    input  wire [1:0]  hint_s,
    input  wire [9:0]  hint_y,
    input  wire        hint_k,          // 行 kind: 0=墙偶步 1=全宽
    // ---- [A3] 需求/驻留观测输出(供顶层 hint 游走器按真实需求/可见区段决策) ----
    output wire        row_covered_o,   // 组合: {hint_s,hint_y,hint_k} 行 bank 已覆盖/在填/在队
    output wire [5:0]  q_occ_o,         // hint 队列占用(0..QDEPTH), 供有界预取反压
    // ---- 消费侧请求(vm_q →; 协议同 v1) ----
    input  wire        cq_v,
    output wire        cq_rdy,
    input  wire        cq_en,
    input  wire [1:0]  cq_slot,
    input  wire [10:0] cq_x,
    input  wire [9:0]  cq_y,
    input  wire [1:0]  cq_tag,
    input  wire        cq_full,         // 1=本请求需全宽覆盖(缩放路径)
    // ---- 消费侧响应(→ fetch; 协议同 v1) ----
    output wire        sq_v,
    output wire        sq_en,
    output wire [15:0] sq_data,
    output wire [1:0]  sq_tag,
    // ---- 帧缓冲侧请求/响应(协议同 v1) ----
    output wire        fq_v,
    input  wire        fq_rdy,
    output wire        fq_en,
    output wire [1:0]  fq_slot,
    output wire [10:0] fq_x,
    output wire [9:0]  fq_y,
    output wire [1:0]  fq_tag,
    input  wire        fs_v,
    input  wire        fs_en,
    input  wire [15:0] fs_data,
    // [E1 修复2] 32 位打包填充响应(fb rd_rsp_w32): FILL 请求一次取回 2 像素,
    //   出口传输时间减半(1280→640 拍/行)。仅填充路径使用; 16 位消费路径不变。
    input  wire [31:0] fs_w32,
    input  wire [1:0]  fs_tag,
    // ---- 观测计数(饱和; 含 v1 全部 G2 计数) ----
    output reg  [15:0] cnt_req,
    output reg  [15:0] cnt_rsp,
    output reg  [15:0] cnt_oob,
    output reg  [15:0] cnt_order_err,
    output reg  [15:0] cnt_drain_err,
    output reg  [15:0] max_noresp,
    output reg  [15:0] max_grant_wait,
    output reg  [15:0] cnt_bank_hit,    // [P2b] bank 命中应答
    output reg  [15:0] cnt_bank_miss,   // [P2b] en=1 miss 入等
    output reg  [15:0] cnt_bypass,      // [P2b] 超时旁路直通数
    output reg  [15:0] cnt_fill_row,    // [P2b] bank 行填充完成数
    // ---- [A3] 首阶段计量: 有效像素欠载 / 请求-响应记分板 / 需求丢失 / 归一化填充 ----
    output reg  [15:0] cnt_underrun,    // [A3→改名] bank 等待周期(C_WAIT 态拍数, 供数欠载)
    output reg  [15:0] cnt_hint_drop,   // [A3] hint valid 但未被接收(需求丢失检查; 应恒 0)
    output reg  [15:0] cnt_fill_dup,    // [A3] 弹出时被去重跳过的重复/无效填充数
    // ---- [方向丙] 墙行需求生命周期归因(墙行 miss 当拍即时判定; 饱和计数) ----
    output reg  [15:0] wm_hit_anom,     // 命中异常: bank 有 tag 匹配但 hit_v 未判中
    output reg  [15:0] wm_infill,       // 在填: 该行正在填充引擎
    output reg  [15:0] wm_queued,       // 排队: 该行在 hint 队列
    output reg  [15:0] wm_evicted,      // 被替换/失效: 该行最近被替换清出
    output reg  [15:0] wm_uncovered,    // 未覆盖: 以上皆非(bank/q/填/失效表都无)
    // ---- [方向丙] 缩放行(全宽需求, cq_full=1)需求生命周期归因(rect 内首错区) ----
    //   与墙行对称, 但缩放行请求要全宽覆盖 ⇒ 多一类"覆盖不足"(撞偶步行)。
    output reg  [15:0] sm_hit_anom,     // 命中异常: 有全宽 tag 匹配但 hit_v 未判中
    output reg  [15:0] sm_cov_insuf,    // 覆盖不足: 有 tag 匹配但是偶步行(bank_full=0)
    output reg  [15:0] sm_infill,       // 在填
    output reg  [15:0] sm_queued,       // 排队
    output reg  [15:0] sm_evicted,      // 被替换/失效
    output reg  [15:0] sm_uncovered,    // 未覆盖
    // ---- [受控实验] 墙 miss 全宽补填占缩放分区计数(m 队列 kind1 全宽补填,
    //   原请求为墙 cq_full=0; 该补填走 kind1 进缩放分区, 挤占缩放行) ----
    output reg  [15:0] cnt_wall_mfill,  // 墙 miss 的全宽补填入队次数(占缩放分区)
    // bank 路标签观测 {v, full, slot, y} ×WAYS
    output wire [WAYS*14-1:0] resid
);
    localparam [1:0] FILL_TAG = 2'd3;    // 填充嗅探标签(消费者 tag ∈ {00,01,10})
    localparam [9:0]  LP10    = LINE_PIX;
    localparam [15:0] BTO     = BOUNCE_TO;
    localparam [5:0]  QD5     = QDEPTH;

    // ====================================================================
    // 填充引擎寄存器(声明前置: 消费侧 fill_present 引用 fstate)
    // ====================================================================
    localparam [1:0] F_IDLE = 2'd0, F_ISSUE = 2'd1, F_DRAIN = 2'd2;
    reg [1:0]  fstate;
    reg [2:0]  fill_way;
    reg [12:0] fill_row;                                 // 弹出行 {kind,slot,y}
    reg [9:0]  iss_l, iss_n, iss_total;                  // 请求侧序号
    reg [9:0]  rsp_n;
    reg  [11:0] filling_tag;
    reg         filling_v;
    // 填充响应事件(声明前置: bank 写/读口块在此之后使用)
    wire fill_rsp = fs_v && (fs_tag == FILL_TAG) && filling_v;

    // ====================================================================
    // bank 存储: WAYS 路 × LINE_PIX×16b, 标签 {slot[1:0], y[9:0]} + full 位
    //   full=1 全宽覆盖; full=0 偶步覆盖(仅 cq_full=0 的墙路径可命中)
    //   [v2.6] WAYS=5 分区: 路 0..2 = 缩放行/miss 补填(kind1 循环);
    //          路 3/4 = 墙行(kind0, 按半区固定) —— 两流互不驱逐
    // ====================================================================
    // [E1 修复2] bank 存储改字编址 320×32(每字 2 相邻像素: 偶 x 低 16 位/奇 x 高
    //   16 位) —— 32 位宽填充响应单写口一次写整字; 消费读出经半字 mux(组合, 在
    //   BRAM 输出寄存之后, 50MHz 时序预算充足)。
    reg [31:0] bank_mem [0:WAYS-1][0:LINE_PIX/2-1];
    reg [WAYS-1:0]    bank_v;
    reg [WAYS-1:0]    bank_full;
    reg [WAYS*12-1:0] bank_t;
    reg [2:0]         bank_lru;                          // kind1 分区循环指针 0..2

    // 覆盖查询: 行 (s,y) 是否已被足够覆盖(need_full=1 须全宽路; =0 偶步即可)。
    //   用于 hint 去重与弹出兜重 [v2.2: WAYS 泛型, 两处实例]
    function row_covered(input [1:0] s, input [9:0] y, input need_full);
        integer i;
        begin
            row_covered = 1'b0;
            for (i = 0; i < WAYS; i = i + 1)
                if (bank_v[i] && bank_t[i*12 +: 12] == {s, y} &&
                    (bank_full[i] || !need_full))
                    row_covered = 1'b1;
        end
    endfunction

    // 消费者命中(覆盖口径; hit_way 须选**满足覆盖**的路)
    wire [WAYS-1:0] hit_v;
    genvar hg;
    generate
        for (hg = 0; hg < WAYS; hg = hg + 1) begin : G_HIT
            assign hit_v[hg] = bank_v[hg] &&
                               (bank_t[hg*12 +: 12] == {cq_slot, cq_y}) &&
                               (bank_full[hg] || !cq_full);
        end
    endgenerate
    wire hit_any = |hit_v;
    // [v2.8] WAYS 泛型优先编码(TB WAYS=4 / 顶层 WAYS=6 共用)
    reg  [2:0] hit_way_r;
    integer hi;
    always @* begin
        hit_way_r = 3'd0;
        for (hi = WAYS - 1; hi >= 0; hi = hi - 1)
            if (hit_v[hi]) hit_way_r = hi[2:0];
    end
    wire [2:0] hit_way = hit_way_r;                      // hit_any 时必有有效路

    // 替换路选择: [v2.6 分区替换] 见 fill 引擎区(pop_row 之后)

    genvar g;
    generate
        for (g = 0; g < WAYS; g = g + 1) begin : G_RES
            assign resid[g*14 +: 14] = {bank_v[g], bank_full[g], bank_t[g*12 +: 12]};
        end
    endgenerate

    // ====================================================================
    // [方向丙] 墙行需求生命周期归因
    //   墙行 miss(cq_full=0 偶步墙行请求未命中)当拍, 对该 {cq_slot,cq_y} 行即时
    //   判定其需求所处环节, 分别饱和计数。七类归约到五个可测状态:
    //     命中异常 / 在填 / 排队 / 被替换失效 / 未覆盖(=未生成或未接受)。
    //   "被替换失效"用最近 4 次失效 tag 表近似(墙行 miss 多在同帧失效后不久发生)。
    // ====================================================================
    // 最近失效 tag 表(环形 4 项): fill_start 替换拍记录被覆写路的旧 tag
    reg [11:0] evict_tag [0:3];
    reg [1:0]  evict_wr;
    wire       wall_miss = miss && !cq_full;                 // 墙行(偶步)miss
    // 命中异常: bank 有路 tag 匹配(同 slot,y)但 hit_v 未判中(覆盖位/逻辑错误)。
    //   墙行请求 cq_full=0, 任何 bank_full 都应命中 ⇒ 有 tag 匹配却没 hit_any 即异常。
    reg        tag_match;
    integer    tm;
    always @* begin
        tag_match = 1'b0;
        for (tm = 0; tm < WAYS; tm = tm + 1)
            if (bank_v[tm] && (bank_t[tm*12 +: 12] == {cq_slot, cq_y}))
                tag_match = 1'b1;
    end
    // 排队判定: 该行在 hint 队列(q_mem 占用区, 从 q_rd 起模 QDEPTH 展开)
    reg        q_wall;
    integer    qw;
    reg [4:0]  qw_idx;
    always @* begin
        q_wall = 1'b0;
        for (qw = 0; qw < QDEPTH; qw = qw + 1) begin
            qw_idx = q_rd[4:0] + qw[4:0];
            if ((qw < (q_wr - q_rd)) && (q_mem[qw_idx][11:0] == {cq_slot, cq_y}))
                q_wall = 1'b1;
        end
    end
    // 在填判定 / 失效表命中判定
    wire infill_wall = filling_v && (filling_tag == {cq_slot, cq_y});
    reg  evict_hit;
    integer ei;
    always @* begin
        evict_hit = 1'b0;
        for (ei = 0; ei < 4; ei = ei + 1)
            if (evict_tag[ei] == {cq_slot, cq_y})
                evict_hit = 1'b1;
    end

    // ---- 缩放行(全宽需求)归因辅助判定 ----
    wire        scale_miss = miss && cq_full;               // 缩放行(全宽)miss
    // 有 tag 匹配且为全宽路(满足覆盖) —— 若存在却仍 miss ⇒ 命中异常
    reg         tag_match_full;
    // 有 tag 匹配但全为偶步行(bank_full=0, 覆盖不足) —— 撞偶步行的缩放行
    reg         tag_match_half;
    integer     tf;
    always @* begin
        tag_match_full = 1'b0;
        tag_match_half = 1'b0;
        for (tf = 0; tf < WAYS; tf = tf + 1)
            if (bank_v[tf] && (bank_t[tf*12 +: 12] == {cq_slot, cq_y})) begin
                if (bank_full[tf]) tag_match_full = 1'b1;
                else               tag_match_half = 1'b1;
            end
    end

    // ====================================================================
    // 消费者状态机(bank 模式; 严格单在途 ⇒ 按序)
    //   IDLE: en1 命中→EMIT; en1 未命中转发→WAITFS 或 miss→WAIT; en0→EMIT(自应答)
    //   WAIT: 行就绪→EMIT; 撤回→IDLE; 超时→BYPASS
    //   BYPASS: fb 就绪受理转发 → WAIT_FS
    //   WAIT_FS: fs 回 → 转发消费者 → IDLE
    //   EMIT: 出数一拍 → IDLE
    // ====================================================================
    localparam [2:0] C_IDLE = 3'd0, C_WAIT = 3'd1, C_BYPASS = 3'd2,
                     C_WAITFS = 3'd3, C_EMIT = 3'd4;
    reg [2:0]  cstate;
    reg        cwait_nofill;                            // [v2.9] C_WAIT 空手等在填行(未入队)
    reg [10:0] fwd_x;
    reg [9:0]  fwd_y;
    reg [1:0]  fwd_slot, fwd_tag;
    reg        fwd_pend;                                 // 转发在途(fs 待回)
    reg [15:0] wait_cnt;
    reg [31:0] emit_w32;                                 // [E1 修复2] bank 字读出寄存
    reg        emit_half;                                // 读出像素的奇偶(随读出寄存)
    wire [15:0] emit_data = emit_half ? emit_w32[31:16] : emit_w32[15:0];
    reg [1:0]  emit_tag;
    reg        emit_en;
    reg        emit_v;

    wire bank_mode_eff = anim_v | emit_v | fwd_pend | (cstate != C_IDLE);

    // 转发意愿(bank 模式): 仅 BYPASS(超时兜底) —— IDLE 未覆盖走 miss 入队
    // (填充后整帧 bank 直答), 覆盖即 bank 命中; en0 走自应答(acc_e0)
    wire fwd_want = anim_v && cq_v && cq_en && (cstate == C_BYPASS);
    wire acc_fwd  = fwd_want && fq_rdy;
    wire acc_bank = anim_v && cq_v && cq_en &&
                    (cstate == C_IDLE || cstate == C_WAIT ||
                     cstate == C_EMIT) && hit_any;   // [v2.12] EMIT 拍也受理: 1 拍/像素
    wire acc_e0   = anim_v && cq_v && !cq_en &&
                    (cstate == C_IDLE || cstate == C_EMIT);   // [v2.12] 同上
    wire acc_b    = acc_fwd | acc_bank | acc_e0;
    wire miss     = anim_v && cq_v && cq_en && (cstate == C_IDLE) && !hit_any;

    // v1 直通受理/出数。[v2.1 修6] 直通响应按 tag 过滤: pending 期填充与消费者
    //   共用 fb 口(填空隙/消隐), 填充响应回流时若不过滤会被 fe 当作消费者响应
    //   ⇒ 整条响应流错位(实测 p3wall 图墙帧像素错位)。消费者 tag ∈ {00,01,10}
    //   (border/pad 互斥), FILL_TAG=3 无歧义。
    wire pt_acc = !bank_mode_eff && cq_v && fq_rdy;
    wire pt_rsp = !bank_mode_eff && fs_v && (fs_tag != FILL_TAG);

    // 统一受理/响应事件(观测)
    wire acc_ev = bank_mode_eff ? acc_b : pt_acc;
    wire rsp_ev = bank_mode_eff ? (emit_v | (fwd_pend && fs_v &&
                                               fs_tag != FILL_TAG)) : pt_rsp;

    assign cq_rdy = bank_mode_eff ? acc_b : fq_rdy;

    // 受理拍锁存(转发; 仅 en1 ⇒ fq_en 恒 1)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fwd_pend <= 1'b0;
            fwd_x <= 11'd0; fwd_y <= 10'd0; fwd_slot <= 2'd0; fwd_tag <= 2'd0;
        end else if (acc_fwd) begin
            fwd_x    <= cq_x;  fwd_y    <= cq_y;
            fwd_slot <= cq_slot; fwd_tag <= cq_tag;
            fwd_pend <= 1'b1;
        end else if (fs_v && fwd_pend && fs_tag != FILL_TAG) begin
            fwd_pend <= 1'b0;                            // 转发响应已交消费者
        end
    end

    // 出数(bank 命中受理 → 下一拍; en0 自应答 → 下一拍标签直答)。
    //   [v2.1 修7] emit_data 不再放本块: bank 读口独立为无复位无条件同步读块
    //   (BRAM 推断口径 —— 读/写寄存器不得带复位), sq_data 侧用 emit_en 掩 e0 数据场。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            emit_v <= 1'b0; emit_en <= 1'b0;
            emit_tag <= 2'd0;
        end else begin
            emit_v <= 1'b0;
            if (acc_bank) begin
                // [v2.12] 连续命中: EMIT 拍受理新请求时也发 emit_v(本拍出数)
                emit_tag  <= cq_tag;
                emit_en   <= 1'b1;
                emit_v    <= 1'b1;
            end else if (acc_e0) begin
                emit_tag  <= cq_tag;
                emit_en   <= 1'b0;
                emit_v    <= 1'b1;
            end
        end
    end

    // [v2.1 修7] bank 读口(无条件同步读; BRAM 输出寄存 + 半字组合选择)
    //   [E1 修复2] 字编址: 读出字由 cq_x[9:1] 索引, 奇偶由 cq_x[0] 同拍寄存
    always @(posedge clk) begin
        emit_w32  <= bank_mem[hit_way][cq_x[9:1]];
        emit_half <= cq_x[0];
    end

    // [v2.1 修7] bank 写口(填充嗅探; 独立无复位块 —— BRAM 推断口径)
    //   [E1 修复2] 字编址单写口: kind1 宽响应整字写入(fs_w32 = 2 像素);
    //   kind0 16 位偶列写入 {16'h0, fs_data}(奇半对本类消费者不可读, 定值防 X)。
    always @(posedge clk)
        if (fill_rsp)
            bank_mem[fill_way][rsp_n[8:0]] <= fill_row[12] ? fs_w32 : {16'h0, fs_data};

    // 状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cstate <= C_IDLE; wait_cnt <= 16'd0; cwait_nofill <= 1'b0;
        end else if (!bank_mode_eff) begin
            cstate <= C_IDLE; wait_cnt <= 16'd0; cwait_nofill <= 1'b0;
        end else begin
            case (cstate)
                C_IDLE: begin
                    wait_cnt <= 16'd0;
                    if (acc_bank)     cstate <= C_EMIT;
                    else if (acc_fwd) cstate <= C_WAITFS;
                    else if (acc_e0)  cstate <= C_EMIT;
                    else if (miss) begin
                        cstate       <= C_WAIT;
                        // [v2.9] 行正在填: 空手等填完(不重复入队); 否则入队
                        cwait_nofill <= fill_match_cq;
                    end
                end
                C_WAIT: begin
                    if (acc_bank) begin
                        cstate <= C_EMIT; cwait_nofill <= 1'b0;
                    end else if (!cq_v) begin
                        cstate <= C_IDLE; cwait_nofill <= 1'b0;  // 消费者撤回(帧边界)
                    end else if (wait_cnt >= BTO) begin
                        cstate   <= C_BYPASS;            // 超时 → 旁路
                        wait_cnt <= 16'd0; cwait_nofill <= 1'b0;
                    end else begin
                        wait_cnt <= wait_cnt + 16'd1;
                        // [v2.9] 空手等待且在填行已完仍不满足 ⇒ 升级已入队一拍
                        if (upg) cwait_nofill <= 1'b0;
                    end
                end
                C_BYPASS: begin
                    if (acc_fwd)    cstate <= C_WAITFS;
                    else if (!cq_v) cstate <= C_IDLE;
                end
                C_WAITFS: if (fs_v && fwd_pend && fs_tag != FILL_TAG)
                              cstate <= C_IDLE;
                // [v2.12] EMIT 拍连续命中受理 ⇒ 下一拍继续 EMIT(服务下一像素);
                //   否则回 IDLE。C_EMIT 的 emit_v 本拍拉高(出数), 与受理并行
                C_EMIT:   cstate <= acc_bank ? C_EMIT :
                                    acc_e0   ? C_EMIT :
                                    miss     ? C_WAIT : C_IDLE;
                default:  cstate <= C_IDLE;
            endcase
        end
    end

    // ====================================================================
    // 填充队列 13b: {kind, slot[1:0], y[9:0]}
    //   入队(单写口, 优先级 miss > hint0 > hint1 > hint2, 每拍至多一行);
    //   入队判覆盖足够 + 正在填充; 弹出再判覆盖(兜重, 修3 同口径)。
    //   [修5] 索引位宽 = 4b(QDEPTH=16; v2 恒 [2:0] 在 >8 项时环回覆写)
    // ====================================================================
    reg [12:0] q_mem [0:QDEPTH-1];
    reg [5:0]  q_wr, q_rd;
    wire       q_empty = (q_wr == q_rd);
    wire       q_full  = ((q_wr - q_rd) >= QD5);
    wire [12:0] q_head = q_mem[q_rd[4:0]];

    // [v2.5 修C] miss 优先队列(2 项): 消费者 miss 插队, 填充引擎先 m 后 q ——
    //   消除 miss 等在 hint 队尾导致的 4096 拍级停顿。
    //   [E1 v3] m 项带 kind(13b {kind,slot,y}): 墙请求(cq_full=0)的 miss 补填
    //   为 kind0 偶步 —— 只补请求实际需要的偶列, 且落墙分区(原恒 kind1 全宽
    //   进缩放分区, 淘汰缩放行 → 缩放 miss → m 洪泛的搅拌放大器, wmf 54→636)。
    localparam MQD = 2;
    reg [12:0] m_mem [0:MQD-1];                    // {kind, slot, y}
    reg [1:0]  m_wr, m_rd;
    wire       m_empty = (m_wr == m_rd);
    wire [1:0] m_cnt   = (m_wr - m_rd);
    wire       m_full  = (m_cnt >= MQD[1:0]);
    wire [12:0] m_head = m_mem[m_rd[0]];
    wire [11:0] m_tag_n = {cq_slot, cq_y};
    wire m_has = (m_cnt == 2'd1) ? (m_mem[m_rd[0]][11:0] == m_tag_n) :
                 (m_cnt == 2'd2) ? ((m_mem[m_rd[0]][11:0] == m_tag_n) ||
                                    (m_mem[~m_rd[0]][11:0] == m_tag_n)) : 1'b0;
    // 去重: bank 已足够覆盖 / 该行正在填(同覆盖度) / 已在 m 队列 ⇒ 不入
    //   [E1 v3] 覆盖度按本请求 kind: 墙请求(cq_full=0)偶步即可覆盖
    wire f_cov_c = filling_v && (filling_tag == m_tag_n) &&
                   (fill_row[12] || !cq_full);
    wire m_skip = row_covered(cq_slot, cq_y, cq_full) || f_cov_c || m_has;
    // [v2.9] 同 tag 行正在填(kind 不论): 消费者 miss 时空手等填完, 不重复
    //   入队 —— 修A 替换拍失效使"在填行"可见为 miss, 原路径会对该行再发一次
    //   kind1 全宽补填(860 拍)且落入缩放分区逐出缩放行(实测每墙行必触发,
    //   级联 miss×2/行, FIFO 永久失血)。等待期填完即命中; 仅当填完仍不
    //   满足覆盖(kind0 填 vs 缩放请求)才补一次全宽升级(C_WAIT 内一次性)
    wire fill_match_cq = filling_v && (filling_tag == m_tag_n);
    wire miss_real = miss && !fill_match_cq;

    wire [12:0] enq_d_miss = {cq_full, cq_slot, cq_y};   // [E1 v3] miss 补填按请求 kind(墙=偶步)
    // hint 去重(覆盖口径): bank 已足够覆盖 或 同行同覆盖度在填 → 不入队
    //   [v2.2] 游走器每拍至多 1 行 ⇒ 单 hint 口(原 3 套寄存/比较为死重)
    wire        f_cov  = filling_v && (filling_tag == {hint_s, hint_y}) &&
                         (fill_row[12] || !hint_k);
    // [A3 统一去重] 覆盖关系去重补全: 除 bank 已 valid(row_covered)+当前在填
    //   (f_cov)外, 再扫 hint 队列 q_mem 全部在队项 —— 同 (slot,y,kind) 已排队
    //   未弹出的不再重复入队(原缺口致同行重复入队挤爆填充引擎, miss 风暴之源)。
    //   覆盖语义: 在队项 kind 与请求 kind 满足"已在队全宽可覆盖偶步请求"视为重复。
    wire [12:0] hint_tag_k = {hint_k, hint_s, hint_y};
    // [缺陷3 修复] 队列环回去重: q_rd/q_wr 是 5 位(0..31 环回计数), q_mem 索引
    //   是 4 位(0..15)。原"索引窗口判定"在 q_wr 回绕后(q_wr[3:0]<q_rd[3:0] 但
    //   5 位值 q_wr>q_rd)误判为不连续窗口 ⇒ 漏判在队项, 去重失效。正确做法:
    //   用占用数 q_occ 展开"从 q_rd 起第 0..q_occ-1 项(索引模 16)", 与计数环回
    //   无关。占用数 q_occ = q_wr - q_rd(5 位无符号差, 恒 ∈ [0,QDEPTH])。
    reg          q_has;
    integer      qi;
    reg   [4:0]  q_idx;
    always @* begin
        q_has = 1'b0;
        for (qi = 0; qi < QDEPTH; qi = qi + 1) begin
            q_idx = q_rd[4:0] + qi[4:0];               // 第 qi 个在队项的物理索引(模QDEPTH)
            if ((qi < (q_wr - q_rd)) &&                             // 该项在占用区间内
                (q_mem[q_idx][11:0] == hint_tag_k[11:0]) &&         // 同 slot,y
                (q_mem[q_idx][12] || !hint_k))                       // 在队全宽可覆盖偶步请求
                q_has = 1'b1;
        end
    end
    // 需求覆盖观测输出(供顶层游走器按真实需求决策): bank 已覆盖/在填/在队 任一即覆盖
    assign row_covered_o = row_covered(hint_s, hint_y, hint_k) || f_cov || q_has;
    wire        h_new  = hint_en && hint_v && hint_rdy &&
                         !row_covered(hint_s, hint_y, hint_k) && !f_cov && !q_has;
    wire [12:0] enq_d_h = {hint_k, hint_s, hint_y};

    // [v2.9] 空手等待升级: 同 tag 在填行已填完仍不满足覆盖(kind0 填 vs 缩放
    //   请求) ⇒ 此刻补一次全宽入队(m 优先, 溢出回退 q 尾)
    wire upg = (cstate == C_WAIT) && cwait_nofill && !filling_v && !hit_any;
    wire enq_m    = (miss_real && !m_skip && !m_full) || (upg && !m_full);
    wire enq_miss = (miss_real && !m_skip && m_full && !q_full) ||
                    (upg && m_full && !q_full);       // 溢出回退 q 尾
    wire        e1 = enq_miss;                        // miss 溢出 → q 尾
    // [A3 有界预取 valid/ready] hint 不再"满则丢"(原会漏关键行, 由 miss 兜底但
    //   已错位); 改 hint_rdy 反压: q 将满时 hint_rdy=0, 顶层游走器停推(hw_hint 不
    //   推进), q 腾出空间再继续 —— 预取有界且需求不丢失(cnt_hint_drop 应恒 0)。
    //   保留 4 项余量: 顶层 hint 是 3 拍/行原子序列(进入时 hint_rdy=1 则整行发完),
    //   留 3 项给在途序列 + 1 项给 miss 溢出回退(e1), 故 hint 接收门限 = QDEPTH-4。
    //   ⇒ 3 拍序列中途 hint_rdy 不翻 0, 序列原子性成立, 无中途丢弃。
    wire        q_nearly_full = ((q_wr - q_rd) >= (QD5 - 6'd4));
    assign      hint_rdy  = hint_en && !q_nearly_full;
    assign      q_occ_o   = (q_wr - q_rd);
    wire        e2 = !miss && h_new;                  // hint_rdy 已在 h_new 内门控
    wire        enq_any = (e1 | e2);
    wire [12:0] enq_d = e1 ? enq_d_miss : enq_d_h;
    // [E1 v2] 被堵队首旋转: q_rd 已在填充块推进, 此处把队首重写到队尾
    //   (与同拍入队互斥: 入队优先, 旋转顺延一拍)。占用不变, 无溢出。
    wire        q_rot = fill_pop && way_block && !fill_pop_m;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_wr <= 6'd0;
        end else if (enq_any) begin
            q_mem[q_wr[4:0]] <= enq_d;
            q_wr <= q_wr + 6'd1;
        end else if (q_rot) begin
            q_mem[q_wr[4:0]] <= q_head;
            q_wr <= q_wr + 6'd1;
        end
    end

    // [v2.5 修C] m 队列写口(独立于 q)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_wr <= 2'd0;
        end else if (enq_m) begin
            m_mem[m_wr[0]] <= {cq_full, m_tag_n};   // [E1 v3] 带请求 kind
            m_wr <= m_wr + 2'd1;
        end
    end

    // ====================================================================
    // 填充引擎(寄存器已前置声明; 本块单写: fstate/fill_*/iss_*/rsp_n/
    //   filling_*/bank_*/q_rd; q_wr 由入队块独占)
    // ====================================================================
    // 填充发射 x 序: [E1 修复2] 两类均字对齐偶步(0,2,..,638, 320 请求) ——
    //   kind1(缩放/miss 补填)用 32 位宽响应一次取回 2 像素(fs_w32), 出口时间
    //   1280→640 拍/行; kind0(墙)仍 16 位响应取偶列(其本就只需偶列, 每字低半)。
    //   [原] kind1 逐像素 640 请求(1280 拍出口) —— 行预算 1587 拍占 81%。
    wire [9:0] iss_x    = {iss_l[8:0], 1'b0};
    wire [9:0] iss_x_nx = {iss_l[8:0], 1'b0} + 10'd2;
    wire        iss_last = (iss_x_nx >= LP10);

    // 填充发射(前向优先: 消费者转发/直通请求让填充整体让位)
    wire fill_want  = hint_en && (fstate == F_ISSUE) && !fwd_want &&
                      (bank_mode_eff || !cq_v);
    wire fill_issue = fill_want && fq_rdy;
    // [v2.5 修C] 弹出优先级: miss 优先队列 > hint 预取队列
    wire fill_pop_m = (fstate == F_IDLE) && hint_en && !m_empty;
    wire fill_pop_q = (fstate == F_IDLE) && hint_en && m_empty && !q_empty;
    wire fill_pop   = fill_pop_m || fill_pop_q;
    wire [12:0] pop_row = fill_pop_m ? m_head : q_head;   // [E1 v3] m 项自带 kind
    wire fill_skip  = fill_pop && row_covered(pop_row[11:10], pop_row[9:0], pop_row[12]);
    // [A3 无可替换路等待/死锁约束] way_all_prot(本类候选路全被消费保护)时:
    //   不启动填充且不弹出(留队首), 等消费者推进、保护解除后再启动 —— 避免强行
    //   覆写驻留行。不会死锁: 被保护的行是消费者正在请求的行, 消费者取走(命中/
    //   直通)后 cq_y 前进, way_prot 随之解除, 下一拍即可启动; 且消费者 miss 由
    //   miss 优先队列/空手等待独立兜底, 不依赖本填充。
    wire way_block   = fill_pop && !fill_skip && way_all_prot;
    wire fill_start  = fill_pop && !fill_skip && !way_all_prot;
    wire fill_done   = (fstate == F_DRAIN) && (rsp_n == iss_total);

    // 替换路选择: [v2.8 分区替换] kind1(缩放行/miss 补填) 在路 0..NW_SCALED-1
    //   循环(工作集 = FE 当前行 + LEAD 预填行 = 2 即足: fill 860 拍 < 1600 拍
    //   行时间, 预填在 FE 到达前完成); kind0(墙行) 固定末 NWALL 路 =
    //   {半区, pair 相位} 2 对×2 半区 —— 墙行按显示行对复用, 覆写仅发生在
    //   更旧 pair 上(FE 早已消费, 数据在显示 FIFO), 竞速消失。
    //   [v2.3 修B 的 prot_way 盲保护被分区取代: 实测最后一次命中几乎恒为
    //   缩放行, 盲保护下墙行仍是牺牲品(p3wall k1 帧 bank 全缩放行实锤)]
    // [E1 WAYS=5 证伪后回退] 恢复参数化分区(WAYS=4→缩放 2 路+墙 2 路)。
    //   实验证据: WAYS=5 无改善(首错/像素错误/欠载不变)且引入 hdrop 回归,
    //   见 archive_e1_ways5_20260927/。
    localparam integer NW_SCALED = (WAYS >= 6) ? 3 : ((WAYS >= 5) ? 2 : WAYS - 2);
    localparam integer NWALL     = WAYS - NW_SCALED;     // 墙路数(3 或 2)
    localparam [2:0] W_WALL0     = NW_SCALED;            // 墙路基址
    reg  [1:0] w_pair;                                   // 半区0 pair 相位
    reg  [2:0] way_sel;
    integer wi;

    // [E1 调度修复 v2: 目标相对保护 + 被堵预取旋转]
    //   v1(仅消费位置保护 y>=last_scale_y 不可淘汰)在 p3wall 实测引发引擎自锁:
    //   队首缩放预取等消费者推进, 消费者推进又等排在后面的墙行填充 ⇒ 循环等待,
    //   只能靠 4096 拍旁路超时逃生(byp 201→5175, gwait 56224) ⇒ 旁路洪泛反饿死
    //   填充口。v2 规则(受害者按"填充目标"相对判定):
    //     可淘汰 = 已过行(y < last_scale_y) ∪ 严格未来行(y > 填充目标y)
    //     保护   = [last_scale_y, 目标y] 区间行(当前消费行必在其中)
    //   ⇒ 现 行 refill(目标=当前行)的受害者全为严格未来行 ⇒ 永远可前进(无死锁);
    //     预取(目标=scan+1)淘汰已过行(常在) ⇒ 正常无堵; 万一全堵, 见下方旋转。
    //   实证机制(不变): 填充未来行淘汰"下一行就要消费的行"→miss→补填级联。
    reg [9:0] last_scale_y;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            last_scale_y <= 10'd0;
        else if (anim_v && cq_v && cq_en && cq_full &&
                 (miss || acc_bank || acc_fwd))
            last_scale_y <= cq_y;      // 消费者缩放位置(miss 时请求已挂起 cq_y 稳定)
    end
    reg [WAYS-1:0] way_prot;
    integer wp;
    always @* begin
        for (wp = 0; wp < WAYS; wp = wp + 1)
            way_prot[wp] = bank_v[wp] && anim_v && cq_v &&
                           (bank_t[wp*12 +: 12] == {cq_slot, cq_y});
    end
    // kind1(缩放)弹出的目标相对保护: 候选路持缩放行 y ∈ [last_scale_y, pop_y]
    //   时保护(pop_y = 本弹出行源 y)。墙分区保持原半区固定路策略, 不叠加。
    reg [WAYS-1:0] way_unpassed;
    integer wu;
    always @* begin
        for (wu = 0; wu < WAYS; wu = wu + 1)
            way_unpassed[wu] = bank_v[wu] && anim_v &&
                               (bank_t[wu*12 +: 10] >= last_scale_y) &&
                               (bank_t[wu*12 +: 10] <= pop_row[9:0]);
    end
    // 无可替换路判定: 本类(kind1→缩放分区 / kind0→墙分区)候选路全被保护 ⇒ 等待
    //   (不强行覆写, 防驻留破坏; 等待期间消费者由 miss 优先队列/空手等待兜底,
    //   不会死锁 —— 见下方 fill_start 的 way_block 处理)。
    reg [WAYS-1:0] way_cand;
    integer wc;
    always @* begin
        // 本弹出行 kind 决定候选路集合
        for (wc = 0; wc < WAYS; wc = wc + 1)
            way_cand[wc] = pop_row[12] ? (wc < NW_SCALED)     // kind1: 缩放分区
                                       : (wc >= NW_SCALED);   // kind0: 墙分区
    end
    // kind1 弹出: 保护 = 精确行保护 ∪ 未过行保护; kind0 弹出: 仅精确行保护
    wire [WAYS-1:0] way_prot_eff = pop_row[12] ? (way_prot | way_unpassed) : way_prot;
    wire way_all_prot = ((way_cand & ~way_prot_eff) == {WAYS{1'b0}}) && (|way_cand);

    always @* begin
        way_sel = bank_lru;
        for (wi = NW_SCALED - 1; wi >= 0; wi = wi - 1)
            if (!bank_v[wi]) way_sel = wi[2:0];
        if (!pop_row[12]) begin                          // kind0: 墙半区(+pair)
            // [v2.10] NWALL=3: 墙左(半区0) 2 对×1 路 + 墙右(半区1) 1 路 ——
            //   墙右单路的 pair 边界覆写竞速由 v2.9 空手等待吸收(430 拍,
            //   FE 每行预算 ~600 拍富余); NWALL>=4: 每半区 2 对无竞速
            if (NWALL >= 4)      way_sel = W_WALL0 + {1'b0, pop_row[10], w_pair[pop_row[10]]};
            else if (NWALL == 3) way_sel = pop_row[10] ? (W_WALL0 + 3'd2)
                                                       : (W_WALL0 + {1'b0, w_pair[0]});
            else                 way_sel = W_WALL0 + {1'b0, pop_row[10]};
        end
        // [A3/E1] 若选中路恰被消费保护且存在未被保护的候选路, 改选未被保护路
        if (way_prot_eff[way_sel] && !way_all_prot) begin
            // 在本类候选路中找第一个未被保护的
            for (wi = WAYS - 1; wi >= 0; wi = wi - 1)
                if (way_cand[wi] && !way_prot_eff[wi]) way_sel = wi[2:0];
        end
    end

    // 响应侧事件(fill_rsp 已前置声明)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fstate <= F_IDLE;
            fill_row <= 13'd0; fill_way <= 2'd0;
            iss_l <= 10'd0; iss_n <= 10'd0; iss_total <= 10'd0;
            rsp_n <= 10'd0;
            filling_v <= 1'b0; filling_tag <= 12'd0;
            bank_v <= {WAYS{1'b0}};
            bank_full <= {WAYS{1'b0}};
            bank_t <= {WAYS*12{1'b0}};
            bank_lru <= 3'd0;
            w_pair <= 2'd0;
            q_rd <= 6'd0;
            m_rd <= 2'd0;
            // 失效表复位与唯一功能写手同块: 同一 reg 分处两个时序块会被综合判多驱动
            //   (TD HDL-8007 ⇒ line_supply 退化成 black box), 仿真器容忍但不可综合。
            evict_wr <= 2'd0;
            evict_tag[0] <= 12'hFFF; evict_tag[1] <= 12'hFFF;
            evict_tag[2] <= 12'hFFF; evict_tag[3] <= 12'hFFF;
        end else begin
            // [v2.1 修7] bank 写已拆至独立无复位块; 此处只推进响应序号(在序)
            if (fill_rsp) begin
                rsp_n <= rsp_n + 10'd1;
            end
            case (fstate)
                F_IDLE: begin
                    // [A3/E1 v2] way_block: 队首(m 外的 q 项)被保护堵住时"旋转"——
                    //   q_rd 前进 + 由入队块把队首重写到队尾(占用不变), 引擎得以
                    //   越过被堵预取继续服务其后墙行填充 ⇒ 无循环等待。m 队项=
                    //   现 行 refill, 其受害者恒为严格未来行 ⇒ 永不堵, 无需旋转。
                    //   fill_skip(弹出兜重)与 fill_start 仍正常弹出。
                    if (fill_pop && way_block && !fill_pop_m) begin
                        q_rd <= q_rd + 6'd1;
                    end else if (fill_pop && !way_block) begin
                        if (fill_pop_m) m_rd <= m_rd + 2'd1;
                        else            q_rd <= q_rd + 6'd1;
                        if (fill_start) begin
                            fill_row  <= pop_row;
                            fill_way  <= way_sel;
                            filling_v   <= 1'b1;
                            filling_tag <= pop_row[11:0];
                            iss_l    <= 10'd0;
                            iss_n    <= 10'd0;
                            rsp_n    <= 10'd0;
                            fstate   <= F_ISSUE;
                            // [v2.8] kind1 分区循环指针 0..NW_SCALED-1(墙行不推进)
                            if (pop_row[12])
                                bank_lru <= (bank_lru >= NW_SCALED[2:0] - 3'd1) ? 3'd0
                                                                                : bank_lru + 3'd1;
                            // [v2.8] kind0 填充翻转该半区 pair 相位(下一对用另一路)
                            if (!pop_row[12])
                                w_pair[pop_row[10]] <= ~w_pair[pop_row[10]];
                            // [v2.3 修A] 替换拍即失效: 在填路对消费者立即视为
                            //   miss(旧标签不得命中"正在被覆写"的路 ⇒ 杜绝
                            //   新旧按列拼接的错数据); 补填经队列, 只慢不错
                            bank_v[way_sel] <= 1'b0;
                            // [方向丙] 记录被覆写路的旧 tag 到失效表(供墙行 miss
                            //   归因"被替换/失效"; 仅当旧行有效才记)
                            if (bank_v[way_sel]) begin
                                evict_tag[evict_wr] <= bank_t[way_sel*12 +: 12];
                                evict_wr <= evict_wr + 2'd1;
                            end
                        end
                    end
                end
                F_ISSUE: begin
                    if (fill_issue) begin
                        iss_l <= iss_l + 10'd1;
                        iss_n <= iss_n + 10'd1;
                        if (iss_last) begin
                            iss_total <= iss_l + 10'd1;
                            fstate    <= F_DRAIN;
                        end
                    end
                end
                F_DRAIN: begin
                    if (fill_done) begin
                        bank_v[fill_way]    <= 1'b1;
                        bank_full[fill_way] <= fill_row[12];
                        bank_t[fill_way*12 +: 12] <= fill_row[11:0];
                        filling_v <= 1'b0;
                        fstate    <= F_IDLE;
                    end
                end
                default: fstate <= F_IDLE;
            endcase
        end
    end

    // ====================================================================
    // fb 口仲裁: 消费者(直通/转发)严格优先, 填充仅空闲拍占用 [修4]
    //   直通模式 = v1 组合直通(cq 直挂 fb 口); 空闲拍字段跟随 cq(与 v1
    //   逐位一致, 不暴露 fill 残留 —— J7 空闲期严格比对依赖此点)
    // ====================================================================
    wire use_cq = bank_mode_eff ? fwd_want : cq_v;
    assign fq_v    = use_cq || fill_want;
    assign fq_en   = bank_mode_eff ? 1'b1 : cq_en;
    assign fq_slot = fill_want ? fill_row[11:10] : cq_slot;
    assign fq_x    = fill_want ? iss_x           : cq_x;
    assign fq_y    = fill_want ? fill_row[9:0]   : cq_y;
    assign fq_tag  = fill_want ? FILL_TAG        : cq_tag;

    // 消费者响应([修6] 直通路径过滤填充响应)
    assign sq_v    = bank_mode_eff ? (emit_v | (fwd_pend && fs_v &&
                                               fs_tag != FILL_TAG))
                                   : (fs_v && (fs_tag != FILL_TAG));
    assign sq_en   = bank_mode_eff ? (emit_v ? emit_en : fs_en) : fs_en;
    assign sq_data = bank_mode_eff ? (emit_v ? (emit_en ? emit_data : 16'd0)
                                             : fs_data) : fs_data;
    assign sq_tag  = bank_mode_eff ? (emit_v ? emit_tag : fs_tag) : fs_tag;

    // ====================================================================
    // 观测计数(v1 语义 + bank 计数; 全饱和)
    // ====================================================================
    reg [7:0]  inflight;
    reg [15:0] noresp;
    reg [15:0] gwait;

    // 无响应窗口: 本拍结算后在途非零且无返回 ⇒ 计入游程
    wire [8:0]  nf = {1'b0, inflight} + {8'b0, acc_ev} - {8'b0, rsp_ev};
    wire        stall_cyc = !rsp_ev && (nf[7:0] != 8'd0);
    wire        wait_g    = cq_v && !cq_rdy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inflight <= 8'd0; noresp <= 16'd0; max_noresp <= 16'd0;
            gwait <= 16'd0; max_grant_wait <= 16'd0;
            cnt_req <= 16'd0; cnt_rsp <= 16'd0; cnt_oob <= 16'd0;
            cnt_order_err <= 16'd0; cnt_drain_err <= 16'd0;
            cnt_bank_hit <= 16'd0; cnt_bank_miss <= 16'd0;
            cnt_bypass <= 16'd0; cnt_fill_row <= 16'd0;
            cnt_underrun <= 16'd0; cnt_hint_drop <= 16'd0; cnt_fill_dup <= 16'd0;
            wm_hit_anom <= 16'd0; wm_infill <= 16'd0; wm_queued <= 16'd0;
            wm_evicted <= 16'd0; wm_uncovered <= 16'd0;
            sm_hit_anom <= 16'd0; sm_cov_insuf <= 16'd0; sm_infill <= 16'd0;
            sm_queued <= 16'd0; sm_evicted <= 16'd0; sm_uncovered <= 16'd0;
            cnt_wall_mfill <= 16'd0;
            // evict_wr / evict_tag 的复位改由唯一功能写手所在块执行(避免多驱动)。
        end else begin
            // [方向丙] 缩放行(全宽)miss 生命周期归因(优先级: 覆盖不足 > 命中异常 >
            //   在填 > 排队 > 被替换 > 未覆盖)。缩放行请求要全宽 ⇒ 撞偶步行是
            //   覆盖不足; 有全宽匹配却 miss 是命中异常。
            if (scale_miss) begin
                if (tag_match_half && !tag_match_full) begin
                    if (sm_cov_insuf != 16'hFFFF) sm_cov_insuf <= sm_cov_insuf + 16'd1;
                end else if (tag_match_full) begin
                    if (sm_hit_anom != 16'hFFFF) sm_hit_anom <= sm_hit_anom + 16'd1;
                end else if (infill_wall) begin
                    if (sm_infill != 16'hFFFF) sm_infill <= sm_infill + 16'd1;
                end else if (q_wall) begin
                    if (sm_queued != 16'hFFFF) sm_queued <= sm_queued + 16'd1;
                end else if (evict_hit) begin
                    if (sm_evicted != 16'hFFFF) sm_evicted <= sm_evicted + 16'd1;
                end else begin
                    if (sm_uncovered != 16'hFFFF) sm_uncovered <= sm_uncovered + 16'd1;
                end
            end
            // [受控实验] 墙 miss 全宽补填占缩放分区: m 入队(enq_m/enq_miss)且
            //   原请求为墙(cq_full=0) ⇒ 该 kind1 全宽补填将进缩放分区, 挤缩放行
            if ((enq_m || enq_miss) && !cq_full && cnt_wall_mfill != 16'hFFFF)
                cnt_wall_mfill <= cnt_wall_mfill + 16'd1;
            // [方向丙] 墙行 miss 生命周期归因(优先级: 命中异常 > 在填 > 排队 >
            //   被替换失效 > 未覆盖; 未覆盖 = 未生成或未接受, 需结合 walker 侧判)
            if (wall_miss) begin
                if (tag_match) begin
                    if (wm_hit_anom != 16'hFFFF) wm_hit_anom <= wm_hit_anom + 16'd1;
                end else if (infill_wall) begin
                    if (wm_infill != 16'hFFFF) wm_infill <= wm_infill + 16'd1;
                end else if (q_wall) begin
                    if (wm_queued != 16'hFFFF) wm_queued <= wm_queued + 16'd1;
                end else if (evict_hit) begin
                    if (wm_evicted != 16'hFFFF) wm_evicted <= wm_evicted + 16'd1;
                end else begin
                    if (wm_uncovered != 16'hFFFF) wm_uncovered <= wm_uncovered + 16'd1;
                end
            end

            // 帧提交点排空检查
            if (frame_start && inflight != 8'd0 && cnt_drain_err != 16'hFFFF)
                cnt_drain_err <= cnt_drain_err + 16'd1;

            if (acc_ev) begin
                if (cnt_req != 16'hFFFF) cnt_req <= cnt_req + 16'd1;
                if (cq_x >= 11'd640 || cq_y >= 10'd480) begin
                    if (cnt_oob != 16'hFFFF) cnt_oob <= cnt_oob + 16'd1;
                end
            end

            if (rsp_ev) begin
                if (cnt_rsp != 16'hFFFF) cnt_rsp <= cnt_rsp + 16'd1;
                if (inflight == 8'd0 && cnt_order_err != 16'hFFFF)
                    cnt_order_err <= cnt_order_err + 16'd1;
            end

            if (acc_bank && cnt_bank_hit != 16'hFFFF)
                cnt_bank_hit <= cnt_bank_hit + 16'd1;
            if (miss && cnt_bank_miss != 16'hFFFF)
                cnt_bank_miss <= cnt_bank_miss + 16'd1;
            if (cstate == C_WAIT && wait_cnt >= BTO && cq_v &&
                cnt_bypass != 16'hFFFF)
                cnt_bypass <= cnt_bypass + 16'd1;
            if (fill_done && cnt_fill_row != 16'hFFFF)
                cnt_fill_row <= cnt_fill_row + 16'd1;

            // ---- [A3] 首阶段计量 ----
            // [缺陷4 修复] 真实欠载计量: 原用 miss 事件(一次性进入等待)计数, 低估
            //   欠载总量且 udr==miss 无信息量。改为按"消费请求受理后处于 C_WAIT
            //   等待态(有请求挂起但无有效数据可给)"的每拍计数 —— C_WAIT 期间消费
            //   者持续欠载, 每拍一次, 真实反映供数欠载总量(与 pixel FIFO 干涸对应)。
            if ((cstate == C_WAIT) && cnt_underrun != 16'hFFFF)
                cnt_underrun <= cnt_underrun + 16'd1;
            // 需求不丢失检查: hint_en && hint_v 有效但 hint_rdy=0(反压未接收)。
            //   A3 握手下顶层应停推, 此计数应恒 0; 非 0 即握手未被顶层遵守(bug)。
            if (hint_en && hint_v && !hint_rdy && cnt_hint_drop != 16'hFFFF)
                cnt_hint_drop <= cnt_hint_drop + 16'd1;
            // 弹出兜重(重复/无效填充): 弹出时 row_covered 命中被跳过(fill_skip) —
            //   该项本不需填(已覆盖), 计入重复/无效统计, 用于阶段1"无效填充下降"判据。
            if (fill_skip && cnt_fill_dup != 16'hFFFF)
                cnt_fill_dup <= cnt_fill_dup + 16'd1;

            if (stall_cyc) begin
                noresp <= (noresp == 16'hFFFF) ? 16'hFFFF : noresp + 16'd1;
                if (noresp != 16'hFFFF && noresp + 16'd1 > max_noresp)
                    max_noresp <= noresp + 16'd1;
            end else begin
                noresp <= 16'd0;
            end

            if (wait_g) begin
                gwait <= (gwait == 16'hFFFF) ? 16'hFFFF : gwait + 16'd1;
                if (gwait != 16'hFFFF && gwait + 16'd1 > max_grant_wait)
                    max_grant_wait <= gwait + 16'd1;
            end else begin
                gwait <= 16'd0;
            end

            if (acc_ev && !rsp_ev) begin
                if (inflight != 8'hFF) inflight <= inflight + 8'd1;
            end else if (rsp_ev && !acc_ev && inflight != 8'd0) begin
                inflight <= inflight - 8'd1;
            end
        end
    end

endmodule
