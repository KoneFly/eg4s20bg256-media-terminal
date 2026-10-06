`timescale 1ns / 1ps
// ============================================================================
// m1a_top — M1a 主应用工程顶层: 真实 TF 卡 -> BMP 上屏 (EG4S20BG256 / HX4S20C)
//
// 集成链路 (全部复用件, 唯一新写 = 本顶层 + SPI 交接 mux + 加载 FSM + LED):
//   clk_50m ─┬─> sdram_clk_gen_50m(PLL1) ─> ctrl 50M 0° / mem 180°
//   SD卡 ─ SPI mux ─> sd_init_sequence(003) ─init_done─┐
//            └───────> fat32_reader(009) <─────────────┘(sel 切换)
//                        │ data_out/data_valid (32bit 大端字流, 无背压)
//                        v
//            bmp_sdram_loader(012 副本, 026 内嵌 bmp_resampler)
//                        │ d_frame_write_done + d_display_* 读端口
//                        v
//            display_fetch_engine ─> async_pixel_fifo(1024×16, AFULL_MARGIN=36)
//                                          ═跨域═> fifo_pixel_source ─┐
//            [026 第三步] res_caption(分辨率字幕, pixel 域) ──数据 mux─┴─AXIS─>
//            [task_040] pixel_adjust(亮度/对比度, 纯组合) + param_osd(参数条)
//              + param_ctrl(拨码 C5~C8 消抖/档位/vsync 换装) ──数据 mux─┘
//            hdmi_1_4b_transmitter_core_wrapper(加密IP) ─> hdmi_phy_wrapper ─> HDMI
//            音频(与视频同 IP 合流): audio_tone_gen / wav_pcm_streamer →
//              audio_src_mux → audio_i2s_bridge(I2S 化投递 + 官方 ACR) → IP
//
// [026 第三步保留段, 只增不改] 基座 = task_026 td_v4p(上板四项 PASS 收口版):
//   * loader.vsync_pulse <= vs_start_pulse(现有 VS 下降沿 CDC 链复用):
//     帧缓冲 active_buffer 只在消隐脉冲拍翻转(VSYNC 帧边界提交, 无撕裂);
//   * loader.src_w/h_out -> 帧提交拍(active_buffer 沿)ctrl 域锁存 ->
//     toggle+32bit 准静态总线 -> res_caption(pixel 域) "宽x高" 白字黑底
//     字幕叠加在 AXIS 数据 mux(仅数据; valid/user/last/ready 直连)。
//
// [027] 本顶层在 026 基座上的改动(仅加载 FSM 调度层 + 按键 + LED 契约):
//   * S_SHOW 死循环 -> 事件驱动 FSM(load_idx_r / key_next / key_auto /
//     auto_cnt / 长按检测); 新增 key_next(B2)/key_auto(C1) 两输入端口;
//   * LED 契约: S_SHOW=当前编号常亮, S_LOAD=编号慢闪(保留 027 版契约);
//   * B2=下一张 / C1 短按=轮播开关 / C1 长按 1s=上一张(教程映射, 主人已裁定)。
//
// 时钟域与复位(019 蓝本逐项一致):
//   * ctrl 域: 板级复位经 clk_50m 两级同步送 PLL1, pll1_locked 经 ctrl_clk
//     两级同步 + 移位释放 core_rst_n; SD/003/009/loader/加载FSM 全在 ctrl 域。
//   * pixel 域: rst_async = ~rst_n | ~pll2_locked, 同步释放 rst_pixel(高有效)。
//   * 异步 FIFO 两侧复位各自域内同步释放; VS 下降沿脉冲 pixel 域产生,
//     ctrl 域 2FF 同步后作为帧获取触发。
//   * SD 引脚在 ctrl 域直接驱动(SCK 由 001 字节引擎按 spi_clk_div 分频)。
//   * 027 按键: key_next/key_auto 板级低有效输入, 消抖与长按检测全在 ctrl 域
//     (无新增跨域)。
//
// SPI 交接 mux(INTERFACE_SPEC §4):
//   sel=0 -> 003(初始化, SCK=50M/(2×(63+1))=390.6kHz); sel=1 -> 009(6.25MHz)。
//   切换条件: init_done && !init_busy(一次性); 切换后等待 ≥4 ctrl 拍才发
//   mount_start。两侧空闲时 cs_n=1/sck=0/mosi=1 完全一致, mux 无毛刺。
//
// 加载 FSM(INTERFACE_SPEC §5; 027 扩展见 doc/spec/behavior_spec.md):
//   IDLE(上电稳定等待 100ms)→INIT→SWITCH→MOUNT→SCAN→LOAD
//   →SHOW, 错误→FAIL(锁存错误码, LED 快闪)。
//   S_LOAD 中 read_start 与 loader.stream_start 同拍发出; 009.read_done 直连
//   loader.stream_done; read_error(码9)优先于 format/size/stream 错误判定。
//   027: S_SHOW 由死循环改为事件驱动——key_next(B2) 消抖按下沿/自动轮播到点
//   → 加载 (hit+1)%4 槽; key_auto(C1) 长按 1s → 加载 (hit+3)%4 槽; C1 短按
//   → auto_en 翻转。S_LOAD 期间按键事件直接忽略(behavior_spec §5 方案 A,
//   防连跳由"事件只在 S_SHOW 产生"保证)。hit_idx_r 只在 loader_load_done
//   拍更新为 load_idx_r(LED 全程显示已上屏的图; read_index 用 load_idx_r)。
//
// [task_036 P3] 四槽常驻缓存 + 一级图墙 + 二级分辨率轮播:
//   * 挂载后按序把卡上全部 PIC(至多 4 张)装入同号 SDRAM 槽(文件 i ⇒ 槽 i, 槽基址
//     i << 19, bank 交错); 上电默认图墙: 四象限各显示一槽(160×120 抽稀 + 2× 块放大),
//     未就绪槽显示占位色, 焦点格加边框。用户切换只在已就绪槽之间进行 ⇒ 恒为命中,
//     切图/切档不产生任何 SD 事务(零读卡); SD 读只发生在上电预取阶段。
//   * 按键: B2 短按(松开沿) = 下一格/下一张, B2 长按 = 进入二级/退回图墙;
//     C1 短按 = 自动轮播开关, C1 长按 = 上一格/上一张。二级满屏按
//     ÷1 → ÷2 → ÷4 每 VIEW_STEP_MS 自动推进一档; 自动轮播开时, 三档走完一轮后换下一张。
//   * 显示取数: 取数引擎逐像素给屏幕坐标 → view_mapper(纯组合)→ 寄存一级 →
//     帧缓冲流式读口(按序响应)→ 着色 → 异步 FIFO。视图参数、焦点、就绪位在
//     vs_start_pulse 拍锁存, 帧中不变(无撕裂)。
//
// LED(022 §7 基础上 027 修改 S_SHOW/S_LOAD, 高电平点亮 A4/A3/C10/B12):
//   INIT 阶段 0000; init 后 0001; 扫描 0111; 加载 = 当前编号慢闪(~1Hz);
//   SHOW = {2'b00,hit_idx_r[1:0]}+1 = 0001~0100 常亮(当前图片编号);
//   FAIL = 错误码(1..9)与 0000 交替快闪(~2Hz)。
//   错误码: 1=CMD0失败 2=ACMD41超时 3=命令超时 4=mount_error 5=无BMP
//           6=format_error 7=size_error 8=stream_error 9=read_error
// ============================================================================

module m1a_top #(
    // 上电稳定等待: 默认 100ms; TB 可覆写小值压缩仿真
    parameter [26:0] PWR_WAIT_TICKS = 27'd5_000_000,
    // LED 快闪/慢闪半周期(默认=真值 ~2Hz/~1Hz; TB 仅仿真加速覆写, TD bit 用默认)
    parameter [24:0] LED_HALF_FAST   = 25'd12_500_000,
    parameter [24:0] LED_HALF_SLOW   = 25'd25_000_000,
    // 003 轮询预算(默认=真卡值; TB 仅仿真加速覆写, TD bit 用默认)
    parameter [15:0] INIT_POLL_MAX    = 16'd2048,
    parameter integer RESCAN_DONE_HOLD_MS = 1000,
    // 027: C1 长按判定/自动轮播周期(默认=真卡值; TB 仅仿真加速覆写, TD bit 用默认)
    parameter integer LONG_PRESS_MS   = 1000,
    parameter integer AUTO_PLAY_MS    = 3000,
    // 032: WAV 播放目标槽选择(0..3)。默认 0 = 交付行为(播槽0 = WAV1.WAV)。
    //   [032 续轮2] 语义变更: 由"编译期固定目标槽"降为**运行时槽的复位初值**
    //   (默认 0 ⇒ 上电行为与旧版逐拍一致); TB 覆写初值的能力保留。
    parameter [1:0]   WAV_PLAY_SLOT   = 2'd0,
    // 032 续: 换歌长按判定窗(ms)。与 C1 的 LONG_PRESS_MS 分开, 因为二者需要
    //   不同的仿真压缩比(换歌台要连按多次, 长阈值会让仿真墙钟爆掉)。
    //   [续轮2 上板反馈] 1000 太贴边界: 消抖要先花 20ms 确认"按下", 长按计数器
    //   才从消抖确认拍开始跑(key_press_debounce.v:56) ⇒ 物理必须按住 >=1.02s。
    //   用户按"1 秒"落在门下时会被判成**短按**而把播放关掉, 再按一次就从该槽
    //   头重播 —— 正是"长按没切换、反而重播 WAV1"的成因之一。
    //   取 500ms: 刻意短按(人手 <=200ms)仍有 2.5x 余量, 而"随手长按 1s"稳定触发
    //   (实际门限 = 500ms + 20ms 消抖 = 0.52s)。调手感只需改这一个参数。
    parameter integer SONG_PRESS_MS   = 500,
    // [task_036 P3] B2 长按(确认/退出)判定窗; 取 500ms 的理由同 SONG_PRESS_MS
    //   (计数从消抖确认拍起算, 1000ms 会让"按住 1 秒"落在门下)。
    parameter integer CONFIRM_PRESS_MS = 500,
    // [task_036 P3] 二级满屏每档停留时长
    parameter integer VIEW_STEP_MS    = 1500
) (
    input  wire        clk_50m,        // R7, 50MHz 板载晶振
    input  wire        rst_n,          // KEY1 (A2), 低有效
    input  wire        key_next,       // KEY_next (B2), 低有效: 短按=下一格/下一张, 长按=进入二级/退回图墙
    input  wire        key_auto,       // KEY4 (C1), 低有效: 短按=上一张/调节项, 单键长按无动作
    input  wire        key_wav,        // KEY_wav (B1/KEY3), 低有效: 短按=播放/停止, 长按=换歌
    input  wire [3:0]  sw,             // 拨码 {SW4,SW3,SW2,SW1}: SW1调节/SW2轮播，拨上=1
    output wire [3:0]  led,            // A4/A3/C10/B12, 高电平点亮
    output wire        sd_dclk,        // A14 (SPI SCK)
    output wire        sd_mosi,        // A13
    input  wire        sd_miso,        // B14
    output wire        sd_ncs,         // A12
    output wire        HDMI_CLK_P,     // C3
    output wire        HDMI_D2_P,      // F1
    output wire        HDMI_D1_P,      // E1
    output wire        HDMI_D0_P,      // G5
    output wire        HDMI_DDC_SCL,   // P2
    inout  wire        HDMI_DDC_SDA    // R2
);

    // --------------------------------------------------------------------
    // 内部连线
    // --------------------------------------------------------------------
    wire ctrl_clk, mem_clk, pll1_locked;
    wire core_rst_n;
    wire pixel_clk, serial_clk, audio_mclk, pll2_locked;
    wire rst_async, rst_pixel;

    wire lrc_entry_valid_w,lrc_sector_req,lrc_sector_done,lrc_sector_valid;
    wire [31:0] selected_pic_cluster_w,selected_pic_size_w;wire [3:0] cached_pic_valid_w;
    wire [1:0] lrc_entry_slot_w;
    wire [31:0] lrc_entry_cluster_w,lrc_entry_size_w,lrc_fat_lba_w,lrc_max_cluster_w,lrc_sector_lba;
    wire [7:0] lrc_sector_byte,lrc_sector_error,lyric_character;
    wire [8:0] lrc_sector_index;
    wire lyric_valid;wire [6:0] lyric_length,lyric_read_column;wire [10:0] lyric_scroll;
    wire wav_buffer_low;
    wire slot_reload_busy;
    (* async_reg="true" *) reg [1:0] wav_low_sync;
    (* async_reg="true" *) reg [1:0] lyric_rst_sync;
    reg lyric_vs_d;
    wire lyric_rst_async=rst_pixel || !core_rst_n;
    wire lyric_rst=lyric_rst_sync[1];
    always @(posedge ctrl_clk or negedge core_rst_n)begin
        if(!core_rst_n)wav_low_sync<=2'b11;else wav_low_sync<={wav_low_sync[0],wav_buffer_low};
    end
    always @(posedge pixel_clk or posedge lyric_rst_async)begin
        if(lyric_rst_async)lyric_rst_sync<=2'b11;else lyric_rst_sync<={lyric_rst_sync[0],1'b0};
    end


    // ---- 加载 FSM / SPI mux 寄存器(集中声明, 全部由 FSM always 块驱动) ----
    reg  [3:0]  fsm_state;
    reg  [26:0] pwr_wait_cnt;               // 上电稳定等待计数
    reg  [1:0]  sw_cnt;                     // S_SWITCH ≥4 拍计数
    reg  [4:0]  query_idx_r;                // 扫描索引
    reg  [4:0]  hit_idx_r;                  // 扫描命中的 BMP 索引
    reg  [1:0]  scan_wait;                  // 每索引等待拍数(≥1, 取 2)
    reg  [3:0]  fail_code;
    reg  [24:0] led_cnt;
    reg         led_tgl;
    reg         sel;                        // SPI mux: 0=003 初始化, 1=009 挂载/读取
    reg         init_start_r;               // 单拍脉冲(默认清零, FSM 转移拍置位)
    reg         mount_start_r;
    reg         read_start_r;
    reg         stream_start_r;
    reg  [21:0] dbg_word_cnt;               // 009 字流字数(M05 观测, 不引出端口)

    // ---- 027: 轮播主控寄存器(behavior_spec §4.2) ----
    reg  [4:0]  load_idx_r;                 // 正在加载的目标槽(S_SHOW 置入, S_LOAD 全程稳定)
    wire        auto_en;                    // SW2消抖电平，拨上开启轮播
    wire        adjust_mode;
    wire        key_param_request, key_param_ack;
    wire [3:0]  key_param_snapshot;
    wire adjust_option;
    reg [102:0] dashboard_snapshot_r;
    reg dashboard_request_r, dashboard_capture_pending;
    wire dashboard_ack;
    (* async_reg = "true" *) reg [1:0] dashboard_ack_sync;
    wire [31:0] wav_samples_consumed;
    wire wav_active;
    wire dashboard_mask, dashboard_text;
    wire dashboard_write_enable, dashboard_ready, dashboard_ready_bank, dashboard_text_ack;
    wire [8:0] dashboard_write_address;
    wire [7:0] dashboard_write_character;
    wire dashboard_help_adjust;
    wire [31:0] dashboard_file_bytes;
    wire dashboard_file_update;
    wire dashboard_file_present, dashboard_total_valid, dashboard_played_valid;
    wire [23:0] dashboard_played, dashboard_total, dashboard_up;

    reg         key4_short_r, rescan_press_r, key_auto_mode_r;
    reg  [31:0] auto_cnt;                   // 轮播计时(仅 S_SHOW 且 auto_en 累计)
    reg  [31:0] long_press_cnt;             // C1 长按计数(按住累加, 松开清零)
    reg         long_press_marked;          // 长按已触发标记(按住不重复; 松开沿判短按)
    reg         key_auto_d;                 // C1 消抖稳定态上一拍(松开沿检测)
    reg         prev_press_r;               // KEY4短按松开单拍脉冲(上一张请求)
    wire        key_next_stable_w;          // B2 消抖稳定态(1=松开 0=按下)
    wire        key_auto_stable_w;          // C1 消抖稳定态(1=松开 0=按下)

    // ---- [task_036 P3] B2 短按/长按检测 ----
    reg  [31:0] b2_cnt;                     // 按住计数(松开清零)
    reg         b2_marked;                  // 本次按住已触发长按(抑制松开沿短按)
    reg         key_next_d;                 // 稳定态上一拍(松开沿检测)
    reg         b2_short_r;                 // 松开沿且未长按 = 短按(单拍)
    reg         b2_long_r;                  // 长按到点(单拍)

    // ---- [task_036 P3] 四槽缓存表 + 视图状态 ----
    reg  [3:0]  slot_present_r;             // 卡上存在 PICi(挂载扫描时确定)
    reg  [3:0]  slot_ready_r;               // 槽 i 已缓存完整一帧
    reg  [63:0] slot_w_r, slot_h_r;         // 槽 i 源图宽/高 = [i*16 +: 16]
    reg  [63:0] slot_cw_r, slot_ch_r;       // [task_037 P-C] 槽 i 存储内容宽/高
                                            // (resampler 几何实际值, 含黑边去除)
    reg  [1:0]  view_mode_r;                // 0=图墙 1=÷1 2=÷2 3=÷4
    reg  [1:0]  display_frame_r;            // 交帧缓冲: 期望显示槽(vsync 拍生效)
    // [P2b] A 类连续缩放动画(设计: doc/P2B_PLAN.md §2)
    reg         anim_busy;                  // 动画进行中(吸收导航; 含触发后首 vsync 前)
    reg         anim_vf;                    // 当前显示帧为动画帧(合成 + ls bank)
    // [C2 时长加倍 2026-09-27] anim_k 扩到 6 位: A 类仍 30 帧(commit@29);
    //   C2 溶解 60 帧(commit@58, 时长加倍), C1 擦除保持 30 帧手感。
    reg  [5:0]  anim_k;                     // 下一渲染帧进度(1..commit-1 渲染; 到 commit 提交)
    reg         anim_exit;                  // 0=进入(墙→二级) 1=退出(二级→墙)
    reg  [1:0]  anim_slot;                  // 目标槽(进入=焦点格; 退出=当前二级槽; C1=新图槽)
    reg  [1:0]  anim_gear;                  // 退出起始档(block_log2: 0/1/2)
    // [C 类 2026-09-27] 二级图墙"内"换图/换档转场(设计: c_wipe.v 头注)
    //   与 A 类共用 anim_busy/anim_k/anim_vf/anim_commit/anim_slot FSM; 区别仅在
    //   合成 mux 走 c_wipe 而非 nn_scaler, 且 line_supply 保持直通(anim_v=0)。
    reg         anim_class;                 // 0=A(墙↔二级缩放) 1=C(图墙内)
    reg         anim_c_sel;                 // 0=C1 异图擦除推拉 1=C2 同图异档溶解
    reg  [1:0]  anim_c_dir;                 // C1 方向 0上→下 1下→上 2左→右 3右→左
    reg  [1:0]  anim_c_src;                 // C1 旧图槽 / C2 当前槽
    reg  [1:0]  anim_c_gear;                // C2 目标档(view_mode: 1/2/3)
    // 提交点按类别: A/C1=29(30帧), C2=58(60帧, 溶解更细腻)
    wire        anim_commit = anim_busy &&
                              (anim_k == ((anim_class && anim_c_sel) ? 6'd58 : 6'd29));

    // ---- [幕布转场 2026-09-29] 交付转向: 一级↔二级切换改用幕布收起/展开,
    //   替代不稳定的 A 类实时缩放(实验保留但默认停用, 证据
    //   archive_e1_experiment_final_20260929/)。复用已验证的静态图墙/满屏路径:
    //   合拢(静态当前视图) → 全黑(交接) → 展开(静态目标视图)。遮罩 = en0 黑
    //   响应(位置守恒); 全黑交接等目标真正就绪(E2 统一提交), 不硬编码帧数。
    localparam integer CURT_STEPS = 8;      // 合拢/展开各 8 帧(半高步进 240/8=30)
    localparam [3:0] CURT_WAIT_MAX = 4'd3;  // 全黑交接等待上限(帧)
    localparam [5:0] CURT_WATCHDOG = 6'd40; // 单次转场总时长上限(帧), 防 curt_busy 常驻
    reg  [1:0]  curt_st;                    // 0=闲置 1=合拢 2=全黑交接 3=展开
    reg         curt_dir;                   // 0=进入(墙→满屏) 1=退出(满屏→墙)
    reg  [4:0]  curt_step;                  // 0..CURT_STEPS 帧步进
    reg  [1:0]  curt_slot;                  // 目标槽(进入=焦点格; 退出=当前二级槽)
    reg         curt_busy;                  // 幕布进行中(吸收导航)
    reg  [3:0]  curt_wait;                  // 已在 st2 等待的帧数(有界交接)
    reg  [5:0]  curt_vs_cnt;                // 本次转场已用帧数(看门狗)
    wire        curt_active = (curt_st != 2'd0);
    wire [8:0]  curt_h = (curt_st == 2'd1) ? (curt_step * 9'd30)
                      : (curt_st == 2'd2) ? 9'd240
                      : (curt_st == 2'd3) ? ((9'd8 - curt_step) * 9'd30)
                      : 9'd0;

    reg  [31:0] step_cnt;                   // 二级每档停留计时
    reg         step_rst_r;                 //

    // 首图优先调度与事务边界软重扫。
    reg  [1:0]  boot_first_slot_r;
    reg         boot_first_loaded_r;
    reg         boot_first_displayed_r;
    reg         boot_first_fetch_started_r;
    reg         boot_prefetch_r;
    reg         boot_frame_request_r;
    wire        boot_frame_complete_w;
    wire        boot_first_complete = boot_first_fetch_started_r &&
                                      (boot_frame_complete_w == boot_frame_request_r);
    reg         rescan_active_r;
    reg         rescan_pending_r;
    reg         rescan_complete_r;
    reg  [31:0] rescan_done_cnt_r;

    // 分段拍数：ctrl_clk = 50MHz，经 LED 读数口保留有效综合扇出。
    (* keep = "true" *) reg [3:0]  boot_meas_stage_r;
    (* keep = "true" *) reg [31:0] boot_meas_stage_cnt_r;
    (* keep = "true" *) reg [31:0] boot_meas_total_cycles_r;
    localparam integer BOOT_IDLE_COUNT_WIDTH = $clog2({5'd0, PWR_WAIT_TICKS} + 32'd2);
    (* keep = "true" *) reg [BOOT_IDLE_COUNT_WIDTH-1:0] boot_meas_idle_cycles_r;
    (* keep = "true" *) reg [31:0] boot_meas_init_cycles_r;
    (* keep = "true" *) reg [2:0] boot_meas_switch_cycles_r;
    (* keep = "true" *) reg [31:0] boot_meas_mount_cycles_r;
    (* keep = "true" *) reg [31:0] boot_meas_scan_cycles_r;
    (* keep = "true" *) reg [31:0] boot_meas_load_first_cycles_r;
    (* keep = "true" *) reg [31:0] boot_meas_load_bg_cycles_r;
    (* keep = "true" *) reg  [2:0] boot_meas_load_count_r;
    (* keep = "true" *) reg         boot_meas_first_show_valid_r;


    // 027 换算周期(参数默认=真卡值; TB 仅仿真加速覆写)
    localparam integer LONG_PRESS_CYCLES = (50_000_000 / 1000) * LONG_PRESS_MS;
    localparam integer AUTO_PLAY_CYCLES  = (50_000_000 / 1000) * AUTO_PLAY_MS;
    localparam integer CONFIRM_CYCLES    = (50_000_000 / 1000) * CONFIRM_PRESS_MS;
    localparam integer VIEW_STEP_CYCLES  = (50_000_000 / 1000) * VIEW_STEP_MS;
    localparam integer RESCAN_DONE_HOLD_CYCLES =
        (50_000_000 / 1000) * RESCAN_DONE_HOLD_MS;

    // ---- [task_032] WAV 播放控制 ----
    //   key_wav(B1) 短按 = 播放/停止切换; 长按 = 换到下一个有效歌槽(032 续)。
    //   长按检测与 027 的 key_auto 同构(计数 + marked 锁存 + 松开沿判短按)。
    wire wav_btn_stable_w;                  // B1 消抖稳定态(1=松开 0=按下)
    reg  wav_btn_d;                         // 上一拍(松开沿检测)
    reg  wav_play_en_c;                     // ctrl 域播放请求电平(跨域前)

    // ---- [task_032 续] 换歌: 运行时槽选择 + 长按检测 + 切槽重载窗 ----
    reg  [1:0]  wav_slot_r;                 // 播放槽 0..3 = WAV1..WAV4
    reg  [31:0] wav_lp_cnt;                 // B1 长按计数(按住累加, 松开清零)
    reg         wav_lp_marked;              // 长按已触发(按住不重复 + 抑制本次短按)
    reg         wav_next_press_r;           // 长按到点单拍脉冲(换歌请求)
    reg  [16:0] wav_reload_t;               // 切槽重载窗剩余拍(0 = 不在窗内)
    reg  [4:0]  wav_reload_min;             // 重载窗最短驻留倒计
    localparam integer SONG_PRESS_CYCLES  = (50_000_000 / 1000) * SONG_PRESS_MS;
    localparam [4:0]  WAV_RELOAD_MIN_CYC = 5'd16;      // ≈0.32us > 数个 pixel_clk
    localparam [16:0] WAV_RELOAD_MAX_CYC = 17'd65000;  // 1.3ms > 一扇区事务 ~330us

    // ---- SD 初始化(003) ----
    wire        init_busy, init_done, init_error;
    wire [7:0]  init_resp_r1_w;                 // raw card answer(诊断观测)  // init_start_r 为 FSM 内 reg
    wire [2:0]  init_error_code;
    wire        card_is_sdhc;
    wire        sd_cs_003, sd_sck_003, sd_mosi_003;

    // ---- FAT32(009) ----
    wire        sd_cs_009, sd_sck_009, sd_mosi_009;
    wire        mount_busy, mount_done, mount_error; // mount_start_r 为 FSM 内 reg
    wire [4:0]  file_count;
    wire [4:0]  query_index_w, read_index_w;         // hit_idx_r 为 FSM 内 reg
    wire [87:0] query_name_w;
    wire [31:0] query_size_w;
    wire        query_is_bmp_w, query_is_wav_w;
    wire        read_busy, read_done, read_error;    // read_start_r 为 FSM 内 reg
    wire [31:0] fat_data_out;
    wire        fat_data_valid;

    // ---- [task_032] WAV 槽(scanner 引出, ctrl 域) ----
    wire [3:0]  wav_valid_w;
    wire [31:0] wav0_first_cluster_w, wav1_first_cluster_w;
    wire [31:0] wav2_first_cluster_w, wav3_first_cluster_w;
    wire [31:0] wav0_size_w, wav1_size_w, wav2_size_w, wav3_size_w;

    // ---- [task_032] FAT32 几何(挂载完成时缓存, 供簇→LBA 换算) ----
    reg  [31:0] geo_data_lba;               // 数据区起始 LBA(data_start_lba)
    reg  [7:0]  geo_spc;                    // 每簇扇区数(sectors_per_cluster)
    wire [31:0] fat_data_start_w;           // fat32_lite 引出(准静态)
    wire [7:0]  fat_spc_w;                  // fat32_lite 引出(准静态)

    // ---- [task_032] 测试音源原始输出(24bit, 波形逻辑未改) ----
    wire        tone_valid;
    wire [23:0] tone_left, tone_right;

    // ---- [task_032] WAV 流器读侧(pixel 域; 由流器实例输出驱动) ----
    wire signed [15:0] wav_pcm_sample;
    wire               wav_pcm_valid;
    wire               wav_stream_active;   // 流器: 播放中(wr 域)
    wire               wav_stream_end;
    wire               wav_track_done_tgl;  // 流器: 曲目播完事件翻转(pixel 域)

    // ---- [task_032] WAV 流器侧 sd_arbiter 端口(wr 域 = ctrl 域) ----
    wire               arb_wav_req, arb_wav_busy, arb_wav_done, arb_wav_valid;
    wire [7:0]         arb_wav_byte, arb_wav_error;
    wire [8:0]         arb_wav_byte_index;
    wire [31:0]        wav_sd_lba_w;        // 流器写侧自维护的请求 LBA

    // ---- [task_032] 显示加载源 → sd_arbiter 的应答镜像 -
    //   fat32_lite 内部 replay 缓冲的输出直接镜像到 fb_sector_*(见其 arb 口),
    //   因此这里只需就绪信号, 无需中间寄存器。
    wire               fb_sector_req, fb_sector_busy, fb_sector_done, fb_sector_valid;
    wire [7:0]         fb_sector_byte, fb_sector_error;
    wire [8:0]         fb_sector_byte_index;
    wire [31:0]        fb_sector_lba;

    // ---- [task_032] sd_arbiter → SD 扇区读链(reader 前端) ----
    wire               sd_arb_req, sd_arb_busy, sd_arb_done, sd_arb_valid;
    wire [7:0]         sd_arb_byte, sd_arb_error;
    wire [8:0]         sd_arb_byte_index;
    wire [31:0]        sd_arb_lba;

    // ---- [task_032] 扫描器源: 挂载期由 fat32_lite 层内直连 reader, 不经顶层
    //   仲裁(互斥时序, 见 fat32_lite)。s2 输入显式接 0 —— 悬空线在综合为 0、
    //   在 4 态仿真为 x, 会经 win_req/win_lba 污染 grant/LBA 判据(LESSON 同类)。

    // ---- loader(012 副本) ----
    wire        loader_stream_ready;                 // stream_start_r 为 FSM 内 reg
    wire        loader_load_busy, loader_load_done;
    wire        loader_fmt_err, loader_sz_err, loader_strm_err;
    wire        loader_init_done, loader_active_buffer;
    wire        fb_fwrite_done;              // loader.d_frame_write_done
    wire [15:0] loader_src_w, loader_src_h;  // [026 第三步] 源图尺寸引出(准静态)
    wire [15:0] loader_cw_w,  loader_ch_w;   // [task_037 P-C] 内容尺寸引出(准静态)

    // ---- [task_046 B3 集成] 选择性加载链(默认优先，无收益几何在写像素前回退) ----
    wire        sel_busy, sel_done, sel_fallback;
    wire [7:0]  sel_error;
    wire [15:0] sel_pix_data, sel_src_w, sel_src_h, sel_cw, sel_ch;
    wire [10:0] sel_pix_x;
    wire [9:0]  sel_pix_y;
    wire        sel_pix_valid, sel_pix_ready;
    wire arb_scan_busy, arb_scan_done, arb_scan_valid;
    wire [7:0] arb_scan_byte, arb_scan_error;
    wire [8:0] arb_scan_byte_index;
    wire        sel_sector_req;
    wire [31:0] sel_sector_lba;
    wire        sel_path_active = sel_busy || !sel_adapter_empty;
    reg         sel_start_r;
    wire        sel_adapter_empty;
    reg  [1:0]  sel_commit_step;             // 0=等 sel_done; 1=已见 sel_done 等 fb 翻转
    reg         sel_commit_seen;             // 两相齐(槽就地就绪)
    reg         fbw_seen;                    // fb 翻转脉冲粘性(脉冲可早于 sel_done)

    // ---- [026 第三步] 分辨率字幕(ctrl 域锁存 + pixel 域叠加) ----
    reg  [15:0] cap_w_c, cap_h_c;            // 帧提交拍锁存的源尺寸
    reg         cap_tgl_c;                   // 锁存事件 toggle(跨 pixel 域)
    wire        cap_mask = dashboard_mask, cap_text = dashboard_text;          // res_caption 叠加输出

    // ---- [task_040] 实时参数调节(pixel 域): 拨码档位 + 像素调节 + 参数条 OSD ----
    wire [7:0]  pa_bri_off;                  // 生效亮度偏移(帧内恒定)
    wire [1:0]  pa_con_sel;                  // 生效对比度档(帧内恒定)
    wire [1:0]  pa_bri_gear, pa_con_gear;    // 生效档位码(OSD 显示)
    wire        pa_upd;                      // vsync 换装拍单拍脉冲
    wire        osd_mask = 1'b0, osd_text = 1'b0;          // 参数条叠加输出
    wire [23:0] adj_axis_data;               // pixel_adjust 输出(与 px_axis_data 同拍)

    // ---- 显示链 ----
    wire [11:0] fe_pos_x, fe_pos_y;          // 取数引擎屏幕坐标
    wire        fe_pos_valid, fe_pos_take;
    wire        fe_wr_en, fe_almost_full;
    wire [15:0] fe_wr_data;
    wire        fe_fetching;
    wire        fetch_frame_accept;          // [A1] FE 实际接受新取数帧的单拍脉冲
    wire        fb_req_ready;                // 帧缓冲读口
    wire        fb_rsp_valid, fb_rsp_en;
    wire [15:0] fb_rsp_data;
    wire [31:0] fb_rsp_w32;                  // [E1 修复2] 32 位打包填充响应
    wire [1:0]  fb_rsp_tag;
    wire [1:0]  fb_active_frame;
    // [幕布] 全黑交接条件(用于 curt_busy FSM 的 st2→st3): 进入 = 目标槽已就绪且
    //   已成为帧缓冲活动帧(视图与槽同帧一致, 杜绝 E2 类"视图先于槽"闪现);
    //   退出 = 回图墙无槽依赖, 整帧切换由 FE 起新帧门控保证。
    wire        curt_handover_ok = curt_dir ? 1'b1
                                 : (slot_ready_r[curt_slot] &&
                                    (fb_active_frame == curt_slot));
    // [task_043 P1] line_supply 供数观测平面(直通; 声明与接线见 u_line_supply)
    wire        fb_req_ready_c;
    wire        fb_req_valid, fb_req_en;
    wire [1:0]  fb_req_slot, fb_req_tag;
    wire [10:0] fb_req_x;
    wire [9:0]  fb_req_y;
    wire        sq_v, sq_en;
    wire [15:0] sq_data;
    wire [1:0]  sq_tag;
    wire [15:0] ls_cnt_req, ls_cnt_rsp, ls_cnt_oob, ls_cnt_order_err, ls_cnt_drain_err;
    wire [15:0] ls_max_noresp, ls_max_grant_wait;
    wire [15:0] ls_cnt_bank_hit, ls_cnt_bank_miss, ls_cnt_bypass, ls_cnt_fill_row;
    wire [55:0] ls_resid;                                // [回退] WAYS=4 × {v,full,slot,y}(14b)
    // [A3] 需求/驻留观测 + 首阶段计量(由 line_supply 输出)
    wire        ls_hint_rdy;                             // hint valid/ready 握手(反压)
    wire        ls_row_covered;                          // 当前 hint 行已覆盖(去重观测)
    wire [5:0]  ls_q_occ;                                // hint 队列占用(有界预取反压; QDEPTH=32)
    wire [15:0] ls_cnt_underrun, ls_cnt_hint_drop, ls_cnt_fill_dup;
    // [方向丙] 墙行需求生命周期归因(墙行 miss 当拍即时判定)
    wire [15:0] ls_wm_hit_anom, ls_wm_infill, ls_wm_queued, ls_wm_evicted, ls_wm_uncovered;
    // [方向丙] 缩放行(全宽)需求生命周期归因(rect 内首错区)
    wire [15:0] ls_sm_hit_anom, ls_sm_cov_insuf, ls_sm_infill, ls_sm_queued, ls_sm_evicted, ls_sm_uncovered;
    // [受控实验] 墙 miss 全宽补填占缩放分区计数
    wire [15:0] ls_cnt_wall_mfill;
    // [P2b] line_supply 动画/bank sideband(anim_v=动画帧标志; hint 由游走器驱动;
    //   v2.2 单 hint 口 —— 游走器每拍至多 1 行)
    reg         ls_hint_v;
    reg  [1:0]  ls_hint_s;
    reg  [9:0]  ls_hint_y;
    reg         ls_hint_k;
    // 映射结果寄存一级(驱动帧缓冲读口, 逻辑见显示链一节)
    reg         vm_q_v, vm_q_en;
    reg  [1:0]  vm_q_slot, vm_q_tag;
    reg  [9:0]  vm_q_x, vm_q_y;
    reg         vm_q_full;               // [P2b v2.1] 缩放路径侧带(需全宽覆盖)

    wire [15:0] src_rd_data;
    wire        src_empty;
    wire        src_rd_en;

    wire v_hs, v_vs, v_de;
    wire vs_fall_pulse, vs_start_pulse;

    wire        axis_s_user, axis_s_valid, axis_s_last, axis_s_ready;
    wire [23:0] axis_s_data;

    wire        audio_valid;
    wire [23:0] audio_left_data, audio_right_data;
    wire        tone_tick;                  // [task_032] 48kHz 时基引出
    wire        audio_valid_pre;            // 音源选择后(未过音量)
    wire [23:0] audio_left_pre, audio_right_pre;
    wire        wav24_valid;                // [task_032] WAV 经 16→24bit 适配后
    wire [23:0] wav24_left, wav24_right;
    wire        acr_valid;
    wire [19:0] acr_cts, acr_n;
    wire [9:0]  tmds_ch0_data, tmds_ch1_data, tmds_ch2_data, tmds_clk_data;
    wire        video_locked;
    wire        edid_read_valid;
    wire [7:0]  edid_read_data;
    wire        ddc_scl;

    // --------------------------------------------------------------------
    // PLL1: SDRAM 双相时钟 (019 蓝本逐项一致)
    // --------------------------------------------------------------------
    reg [1:0] rst_sync_50m;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) rst_sync_50m <= 2'b00;
        else        rst_sync_50m <= {rst_sync_50m[0], 1'b1};
    end
    wire pll1_rst_n = rst_sync_50m[1];

    sdram_clk_gen_50m u_sdram_pll (
        .ref_clk    (clk_50m),
        .pll_rst_n  (pll1_rst_n),
        .ctrl_clk   (ctrl_clk),
        .mem_clk    (mem_clk),
        .pll_locked (pll1_locked)
    );

    // ctrl 域复位: pll_locked 两级同步后移位释放 (019 蓝本)
    reg  [1:0] locked_sync;
    reg  [2:0] rst_ctrl_shift;
    always @(posedge ctrl_clk or negedge rst_n) begin
        if (!rst_n) begin
            locked_sync    <= 2'b00;
            rst_ctrl_shift <= 3'b000;
        end else begin
            locked_sync <= {locked_sync[0], pll1_locked};
            if (locked_sync[1])
                rst_ctrl_shift <= {rst_ctrl_shift[1:0], 1'b1};
        end
    end
    assign core_rst_n = rst_ctrl_shift[2];

    // --------------------------------------------------------------------
    // PLL2: HDMI 时钟 + pixel 域复位 (019 蓝本)
    // --------------------------------------------------------------------
    hdmi_pll u_hdmi_pll (
        .ref_clk    (clk_50m),
        .pll_rst_n  (rst_n),
        .pixel_clk  (pixel_clk),
        .serial_clk (serial_clk),
        .audio_mclk (audio_mclk),
        .pll_locked (pll2_locked)
    );

    reg [1:0] rst_pixel_sync;
    assign rst_async = ~rst_n | ~pll2_locked;
    always @(posedge pixel_clk or posedge rst_async) begin
        if (rst_async)
            rst_pixel_sync <= 2'b11;
        else
            rst_pixel_sync <= {rst_pixel_sync[0], 1'b0};
    end
    assign rst_pixel = rst_pixel_sync[1];
    // PHY使用原像素复位末级的等价局部副本，异步置位和两拍释放语义相同。
    (* preserve = "true", max_fanout = 8 *) reg rst_pixel_phy;
    always @(posedge pixel_clk or posedge rst_async) begin
        if(rst_async) rst_pixel_phy <= 1'b1;
        else rst_pixel_phy <= rst_pixel_sync[0];
    end


    // --------------------------------------------------------------------
    // SPI 交接 mux (§4: S1)
    //   sel 寄存器在加载 FSM always 块内驱动(§4 S2 条件 + 复位值 0),
    //   避免多驱动。两侧空闲输出完全一致(cs_n=1/sck=0/mosi=1), 切换无毛刺。
    // --------------------------------------------------------------------
    assign sd_ncs  = sel ? sd_cs_009  : sd_cs_003;
    assign sd_dclk = sel ? sd_sck_009 : sd_sck_003;
    assign sd_mosi = sel ? sd_mosi_009: sd_mosi_003;

    // --------------------------------------------------------------------
    // SD 初始化序列 (003, ctrl 域)
    //   spi_clk_div_slow=63 -> SCK=50M/(2×(63+1))=390.6kHz(≤400kHz); fast 透传(003 不消费)。
    //   INIT_POLL_MAX=600: 真卡 ACMD41 轮询预算 ~0.47s(§8 "≥100 或放大"的
    //   登记值; 仿真场景假卡 2 拍即就绪, 不触及)。
    // --------------------------------------------------------------------
    sd_init_sequence #(
        .INIT_POLL_MAX (INIT_POLL_MAX)   // 默认 2048=真卡预算(TB 仅仿真加速覆写)
    ) u_sd_init (
        .clk              (ctrl_clk),
        .rst_n            (core_rst_n),
        .init_start       (init_start_r),
        .init_busy        (init_busy),
        .init_done        (init_done),
        .init_error       (init_error),
        .init_error_code  (init_error_code),
        .card_is_sdhc     (card_is_sdhc),
        .init_resp_r1     (init_resp_r1_w),   // 诊断观测, 本层不消费
        .spi_cs_n         (sd_cs_003),
        .spi_sck          (sd_sck_003),
        .spi_mosi         (sd_mosi_003),
        .spi_miso         (sd_miso),
        .spi_clk_div_slow (16'd63),
        .spi_clk_div_fast (16'd3)
    );

    // --------------------------------------------------------------------
    // FAT32 只读层 (fat32_lite, 米醋 FAT32 栈适配层; 对外接口不变)
    //   ctrl 域; 实际 SCK 由 fat32_lite 内 SPI_CLK_DIV_SIM 常量决定(米醋
    //   字节引擎按 2×CLK_DIV 分频): [2026-09-21 提速] 真值 7→2, SCK
    //   3.57→12.5MHz(SD SPI 规范 25MHz 内; 640×480 切换纯传输 2.06s→
    //   0.59s, 切换过慢主因修复)。注: 026 注释"SCK=50M/(2×3)=8.33MHz"
    //   系公式误记且端口未接线提速从未生效, 本轮由 RTL 内常量真实生效。
    //   data 流无背压(SPI 节拍供字, loader 消费更快, 无害)。
    // --------------------------------------------------------------------
    fat32_lite #(
        .BYTE_DIV_WIDTH (16),
        .MAX_FILES      (16)
    ) u_fat (
        .clk          (ctrl_clk),
        .rst_n        (core_rst_n),
        .init_ready   (init_done),       // 003 init_done(单拍, 适配层内锁存)
        .card_high_capacity (card_is_sdhc),   // 003 容量类型(SDHC 假设值)
        .mount_start  (mount_start_r),
        .mount_busy   (mount_busy),
        .mount_done   (mount_done),
        .mount_error  (mount_error),
        .file_count   (file_count),
        .query_index  (query_index_w),
        .query_name   (query_name_w),
        .query_size   (query_size_w),
        .query_is_bmp (query_is_bmp_w),
        .query_is_wav (query_is_wav_w),
        .read_start   (read_start_r),
        .read_index   (read_index_w),
        .read_busy    (read_busy),
        .read_done    (read_done),
        .read_error   (read_error),
        .data_out     (fat_data_out),
        .data_valid   (fat_data_valid),
        // [task_032] WAV 槽与几何引出(纯新增, 不影响 PIC 槽/冻结接口语义)
        .wav_valid            (wav_valid_w),
        .wav0_first_cluster   (wav0_first_cluster_w),
        .wav1_first_cluster   (wav1_first_cluster_w),
        .wav2_first_cluster   (wav2_first_cluster_w),
        .wav3_first_cluster   (wav3_first_cluster_w),
        .wav0_size            (wav0_size_w),
        .wav1_size            (wav1_size_w),
        .wav2_size            (wav2_size_w),
        .wav3_size            (wav3_size_w),
        .selected_pic_cluster(selected_pic_cluster_w),.selected_pic_size(selected_pic_size_w),.cached_pic_valid(cached_pic_valid_w),
        .lrc_entry_valid(lrc_entry_valid_w),.lrc_entry_slot(lrc_entry_slot_w),
        .lrc_entry_cluster(lrc_entry_cluster_w),.lrc_entry_size(lrc_entry_size_w),
        .lrc_fat_start(lrc_fat_lba_w),.lrc_max_cluster(lrc_max_cluster_w),
        .data_start_lba_out   (fat_data_start_w),
        .sectors_per_cluster_out (fat_spc_w),
        // [task_032] 三源仲裁: 显示加载/WAV 走 sd_arbiter; 扫描器仍在 fat32_lite 内
        //   直连 reader(挂载期与显示加载时序互斥, 保留原内部分派)。
        //   文件流器扇区口外引, 经顶层 sd_arbiter 仲裁后由 arb_sector_* 回灌。
        .file_sector_req      (fb_sector_req),
        .file_sector_lba      (fb_sector_lba),
        .file_sector_busy     (fb_sector_busy),
        .file_sector_valid    (fb_sector_valid),
        .file_sector_byte     (fb_sector_byte),
        .file_sector_byte_index(fb_sector_byte_index),
        .file_sector_done     (fb_sector_done),
        .file_sector_error    (fb_sector_error),
        .arb_sector_req       (sd_arb_req),
        .arb_sector_lba       (sd_arb_lba),
        .arb_sector_busy      (sd_arb_busy),
        .arb_sector_valid     (sd_arb_valid),
        .arb_sector_byte      (sd_arb_byte),
        .arb_sector_byte_index(sd_arb_byte_index),
        .arb_sector_done      (sd_arb_done),
        .arb_sector_error     (sd_arb_error),
        .spi_cs_n     (sd_cs_009),
        .spi_sck      (sd_sck_009),
        .spi_mosi     (sd_mosi_009),
        .spi_miso     (sd_miso),
        .spi_clk_div  (16'd2)   // 冻结接口占位, fat32_lite 不消费(实际分频=其
                                 // 内部 SPI_CLK_DIV_SIM=2, SCK=12.5MHz, 见上块注释);
                                 // 米醋栈 sd_spi_sector_reader 含 CRC16 校验,
                                 // 信号劣化报 ERR_DATA_CRC 而非静默花屏
    );

    // --------------------------------------------------------------------
    // BMP->SDRAM 加载器 (012 副本, 显示读端口组已引出 §2.2)
    // --------------------------------------------------------------------
    bmp_sdram_loader #(
        .FRAME_WIDTH    (640),
        .FRAME_HEIGHT   (480),
        .FIFO_DEPTH     (32),
        .PIX_FIFO_DEPTH (32),
        .REF_CYCLES_CTRL(781)           // tREFI 15.625us @50MHz
    ) u_loader (
        .ctrl_clk     (ctrl_clk),
        .sdram_clk    (mem_clk),
        .rst_n        (core_rst_n),
        .stream_start (stream_start_r),
        .data_in      (fat_data_out),
        .data_valid   (fat_data_valid),
        .stream_done  (read_done),
        .stream_ready (loader_stream_ready),
        .load_busy    (loader_load_busy),
        .load_done    (loader_load_done),
        .format_error (loader_fmt_err),
        .size_error   (loader_sz_err),
        .stream_error (loader_strm_err),
        // 012 verify 路径本顶层不复用(显示读走 d_display_*), verify_req 恒 0
        .verify_req   (1'b0),
        .verify_x     (11'd0),
        .verify_y     (10'd0),
        .verify_data  (),
        .verify_valid (),
        // [task_036 P3] 帧缓冲四槽流式读口(寄存一级后经 line_supply 接入, 见显示链)
        .d_rd_req_valid     (fb_req_valid),
        .d_rd_req_ready     (fb_req_ready),
        .d_rd_req_en        (fb_req_en),
        .d_rd_req_slot      (fb_req_slot),
        .d_rd_req_x         (fb_req_x),
        .d_rd_req_y         (fb_req_y),
        .d_rd_req_tag       (fb_req_tag),
        .d_rd_rsp_valid     (fb_rsp_valid),
        .d_rd_rsp_data      (fb_rsp_data),
        .d_rd_rsp_w32       (fb_rsp_w32),
        .d_rd_rsp_en        (fb_rsp_en),
        .d_rd_rsp_tag       (fb_rsp_tag),
        .d_frame_write_done (fb_fwrite_done),
        .write_frame        (load_idx_r[1:0]),   // 文件 i 装入槽 i(S_LOAD 全程稳定)
        .display_frame      (display_frame_r),
        .active_frame       (fb_active_frame),
        // VSYNC 帧边界: 复用现有 VS 下降沿 CDC 单拍脉冲, 显示槽只在该消隐窗切换
        .vsync_pulse        (vs_start_pulse),
        .src_w_out          (loader_src_w),
        .src_h_out          (loader_src_h),
        .content_w_o        (loader_cw_w),
        .content_h_o        (loader_ch_w),
        .init_done          (loader_init_done),
        .active_buffer      (loader_active_buffer),
        // [task_046 B3 集成 diff] 选择性加载像素注入(见模块端口注释)
        .sel_mode      (sel_path_active),
        .sel_pix_data  (sel_pix_data),
        .sel_pix_x     (sel_pix_x),
        .sel_pix_y     (sel_pix_y),
        .sel_pix_valid (sel_pix_valid),
        .sel_pix_ready (sel_pix_ready)
    );

    // --------------------------------------------------------------------
    // [task_046 B3 集成] 选择性加载顶层(新路径; s2 独占用仲裁器空闲源)
    //   (sel_path_active/sel_start_r/sel_adapter_empty 声明在前方线束块)
    // --------------------------------------------------------------------
    bmp_selective_load_top #(.USE_MOUNT_CACHE(1'b1)) u_sel (
        .clk          (ctrl_clk),
        .rst_n        (core_rst_n),
        .cache_ready(geo_spc!=0 && sel),.cache_pic_valid(cached_pic_valid_w),
        .cache_cluster(selected_pic_cluster_w),.cache_size(selected_pic_size_w),
        .cache_spc(geo_spc),.cache_fat_lba(lrc_fat_lba_w),.cache_data_lba(geo_data_lba),.cache_max_cluster(lrc_max_cluster_w),
        .sel_start    (sel_start_r),
        .sel_index    (load_idx_r[1:0]),
        .sel_busy     (sel_busy),
        .sel_done     (sel_done),
        .sel_error    (sel_error),
        .sel_fallback (sel_fallback),
        .sector_req   (sel_sector_req),
        .sector_lba   (sel_sector_lba),
        .sector_busy  (arb_scan_busy),
        .sector_valid (arb_scan_valid),
        .sector_byte  (arb_scan_byte),
        .sector_byte_index(arb_scan_byte_index),
        .sector_done  (arb_scan_done),
        .sector_error (arb_scan_error),
        .pix_data     (sel_pix_data),
        .pix_x        (sel_pix_x),
        .pix_y        (sel_pix_y),
        .pix_valid    (sel_pix_valid),
        .pix_ready    (sel_pix_ready),
        .sel_src_w    (sel_src_w),
        .sel_src_h    (sel_src_h),
        .sel_cw       (sel_cw),
        .sel_ch       (sel_ch),
        .adapter_empty(sel_adapter_empty)
    );

    // --------------------------------------------------------------------
    // 分辨率字幕尺寸锁存(ctrl 域)
    //   [task_037 P-C] 字幕分辨率随视图(主人 09-24 裁定口径):
    //     图墙(view 0)       = 焦点槽**源**分辨率(slot_w/h_r, 现状保持);
    //     二级 ÷k(view 1..3) = 该槽帧缓冲**存储内容尺寸**(slot_cw/ch_r =
    //       resampler 几何实际值, 非 4:3 源有黑边) ÷ k, k = 2^(view-1) 移位实现。
    //   锁存条件: vs_start_pulse 拍(与视图参数 view_v/focus_v 同拍, 与该帧
    //   图像严格同批)焦点槽已就绪, 且 (视图变化 ∨ 尺寸变化) —— 视图变化纳入
    //   后"换图但尺寸相同"也重新锁存(重写同值无害, 不漏更新); res_caption
    //   在 pixel 域 2FF 同步 toggle 后捕获(总线准静态稳定, 一致快照)。
    // --------------------------------------------------------------------
    wire [15:0] focus_w  = slot_w_r[{hit_idx_r[1:0], 4'd0} +: 16];
    wire [15:0] focus_h  = slot_h_r[{hit_idx_r[1:0], 4'd0} +: 16];
    wire [15:0] focus_cw = slot_cw_r[{hit_idx_r[1:0], 4'd0} +: 16];
    wire [15:0] focus_ch = slot_ch_r[{hit_idx_r[1:0], 4'd0} +: 16];
    // [P2b v2.1] 采样修正: cap 块与 FSM 同沿读 view_mode_r/hit_idx_r 为沿前值,
    //   动画提交在该沿改写视图 ⇒ 提交帧字幕会滞后一帧(与帧内容不同步)。
    //   提交拍改采样提交结果(entry→÷1/anim_slot; exit→图墙/现槽)。
    wire        cap_anim_c = vs_start_pulse && anim_commit;
    wire [1:0]  cap_vw_s   = cap_anim_c ? ((anim_exit) ? 2'd0 : 2'd1) : view_mode_r;
    wire [1:0]  cap_hit_s  = cap_anim_c ? anim_slot : hit_idx_r[1:0];
    wire [15:0] capF_w     = cap_anim_c ? slot_w_r[{anim_slot, 4'd0} +: 16]  : focus_w;
    wire [15:0] capF_h     = cap_anim_c ? slot_h_r[{anim_slot, 4'd0} +: 16]  : focus_h;
    wire [15:0] capF_cw    = cap_anim_c ? slot_cw_r[{anim_slot, 4'd0} +: 16] : focus_cw;
    wire [15:0] capF_ch    = cap_anim_c ? slot_ch_r[{anim_slot, 4'd0} +: 16] : focus_ch;
    // ÷k 移位量: view 1→0, 2→1, 3→2; view 0 的移位值被输出 mux 绕开
    wire [2:0]  cap_sh    = {2'b00, cap_vw_s - 2'd1};
    wire [15:0] cap_sec_w = capF_cw >> cap_sh;
    wire [15:0] cap_sec_h = capF_ch >> cap_sh;
    wire [15:0] cap_next_w = (cap_vw_s == 2'd0) ? capF_w  : cap_sec_w;
    wire [15:0] cap_next_h = (cap_vw_s == 2'd0) ? capF_h  : cap_sec_h;
    reg         cap_view_c;   // 字幕现值对应视图(视图变化触发重锁存)
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            cap_w_c   <= 16'd0;
            cap_h_c   <= 16'd0;
            cap_tgl_c <= 1'b0;
            cap_view_c <= 2'd0;
        end else if (vs_start_pulse && slot_ready_r[cap_hit_s]) begin
            cap_w_c    <= cap_next_w;
            cap_h_c    <= cap_next_h;
            cap_view_c <= cap_vw_s;
            cap_tgl_c  <= ~cap_tgl_c;
        end
    end

    // --------------------------------------------------------------------
    // 027: 按键消抖 ×2 + C1 长按/短按检测 (ctrl 域, behavior_spec §2/§3)
    //   [task_036 P3] B2 与 C1 同构: 只取消抖稳定态, 长按计数 + 松开沿判短按
    //   由顶层检测器完成(消抖 press_pulse 悬空不接)。
    // --------------------------------------------------------------------
    key_press_debounce #(
        .CLK_FREQ_HZ (50_000_000),
        .DEBOUNCE_MS (20)
    ) u_deb_next (
        .clk              (ctrl_clk),
        .rst_n            (core_rst_n),
        .button_in        (key_next),
        .press_pulse      (),
        .button_stable_out(key_next_stable_w)
    );

    key_press_debounce #(
        .CLK_FREQ_HZ (50_000_000),
        .DEBOUNCE_MS (20)
    ) u_deb_auto (
        .clk              (ctrl_clk),
        .rst_n            (core_rst_n),
        .button_in        (key_auto),
        .press_pulse      (),             // C1 事件由下方检测器产生
        .button_stable_out(key_auto_stable_w)
    );

    // [task_032] C2(WAV 播放开关)消抖: 仅需稳定态, 松开沿在 wav_play 逻辑里检
    key_press_debounce #(
        .CLK_FREQ_HZ (50_000_000),
        .DEBOUNCE_MS (20)
    ) u_deb_wav (
        .clk              (ctrl_clk),
        .rst_n            (core_rst_n),
        .button_in        (key_wav),
        .press_pulse      (),
        .button_stable_out(wav_btn_stable_w)
    );

    // C1 长按检测 + 短按轮播开关 + 自动轮播计时: 见 FSM localparam 之后的
    // 两个 always 块(引用 S_SHOW, 置于其声明后, 避免前向引用)。
    // --------------------------------------------------------------------
    // 加载 FSM (§5, ctrl 域)
    // --------------------------------------------------------------------
    localparam [3:0]
        S_IDLE   = 4'd0,
        S_INIT   = 4'd1,
        S_SWITCH = 4'd2,
        S_MOUNT  = 4'd3,
        S_SCAN   = 4'd4,
        S_LOAD   = 4'd5,
        S_SHOW   = 4'd6,
        S_FAIL   = 4'd7;

    assign query_index_w = query_idx_r;
    assign read_index_w  = load_idx_r;   // 027: S_LOAD 读目标槽(022 为 hit_idx_r);
                                         // load_idx_r 在 S_LOAD 全程稳定(fat32_lite
                                         // 要求 read_index 读期间保持不变)

    // 索引回绕 (behavior_spec §4.3, 全 5 位比较, 无位选同余别名):
    // 值域封闭性: hit_idx_r 复位 0, 仅 SCAN(0..3)与 load_done(load_idx_r∈0..3)
    // 赋值 => 恒 ∈{0,1,2,3}, [1:0] 截位与全值等价(唯一截位点=LED 编码)。
    function [4:0] next_index_of;
        input [4:0] cur;
        begin
            next_index_of = (cur == 5'd3) ? 5'd0 : (cur + 5'd1);
        end
    endfunction

    function [4:0] prev_index_of;
        input [4:0] cur;
        begin
            prev_index_of = (cur == 5'd0) ? 5'd3 : (cur - 5'd1);
        end
    endfunction

    // KEY4单键: 短按上一张/调节项切换，长按无动作；KEY2+KEY4长按软重扫。
    // 组合键接管后吸收两键事件直到全部松开; 沿用C1计数器计满组合按住1s。
    reg rescan_chord_seen_r;
    wire rescan_chord_held = !key_next_stable_w && !key_auto_stable_w;
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            long_press_cnt    <= 32'd0;
            long_press_marked <= 1'b0;
            prev_press_r      <= 1'b0;
            key_auto_d        <= 1'b1;
            key4_short_r <= 1'b0;
            rescan_press_r <= 1'b0;
            key_auto_mode_r <= 1'b0;
            rescan_chord_seen_r <= 1'b0;
        end else begin
            prev_press_r <= 1'b0;
            key4_short_r <= 1'b0;
            rescan_press_r <= 1'b0;
            key_auto_d   <= key_auto_stable_w;
            if (!key_auto_stable_w && key_auto_d)
                key_auto_mode_r <= adjust_mode;
            if (key_next_stable_w && key_auto_stable_w)
                rescan_chord_seen_r <= 1'b0;
            if (rescan_chord_held && !rescan_chord_seen_r) begin
                rescan_chord_seen_r <= 1'b1;
                long_press_cnt <= 32'd0;
                long_press_marked <= 1'b0;
            end else if (rescan_chord_seen_r && !rescan_chord_held) begin
                long_press_cnt <= 32'd0;
                long_press_marked <= 1'b1;
            end else if (!key_auto_stable_w) begin
                if (long_press_cnt < LONG_PRESS_CYCLES - 1) begin
                    long_press_cnt <= long_press_cnt + 32'd1;
                end else if (!long_press_marked) begin
                    long_press_marked <= 1'b1;
                    if (rescan_chord_seen_r)
                        rescan_press_r <= 1'b1;
                end
            end else begin
                long_press_cnt    <= 32'd0;
                long_press_marked <= 1'b0;
                if (!key_auto_d && !long_press_marked &&
                    key_auto_mode_r == adjust_mode) begin
                    key4_short_r <= 1'b1;
                    if (!adjust_mode)
                        prev_press_r <= 1'b1;
                end
            end
        end
    end

    // 自动轮播到点(组合, 仅被 FSM 时序块同步采样, 无边沿敏感观察者):
    // SW2关闭与计数到点同拍时，按当前电平抑制事件。
    // 上电稳定等待结束后，先看到两键均释放才接受组合重扫。
    // 启动阶段按住或不确定的输入不能排入重扫；释放后仍保留LOAD忙态受理。
    reg rescan_armed_r;
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n)
            rescan_armed_r <= 1'b0;
        else if (fsm_state != S_IDLE && key_next_stable_w && key_auto_stable_w)
            rescan_armed_r <= 1'b1;
    end
    wire rescan_request = rescan_armed_r && rescan_press_r && rescan_chord_seen_r &&
                          ((fsm_state == S_SHOW) || (fsm_state == S_FAIL) || (fsm_state == S_LOAD));
    wire rescan_quiescent = !init_busy && !mount_busy && !read_busy &&
                            !loader_load_busy && !sel_busy && !arb_wav_busy &&
                            !arb_wav_req && !fb_sector_busy && !fb_sector_req &&
                            !sd_arb_busy && !sd_arb_req && !arb_scan_busy && !sel_sector_req;
    // 重扫排空条件先锁存, pending期间禁止新请求/导航, 下一拍统一交付。
    reg rescan_start_r;
    wire rescan_accept = rescan_pending_r && rescan_quiescent &&
                         ((fsm_state == S_SHOW) || (fsm_state == S_FAIL)) &&
                         !anim_busy && !curt_busy;
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n)
            rescan_start_r <= 1'b0;
        else
            rescan_start_r <= rescan_accept && !rescan_start_r;
    end
    wire rescan_start = rescan_start_r;
    // KEY2 + KEY3 同时按住进入观测；SW 选页，LED 按半秒输出高位优先的十六进制。
    wire boot_metrics_mode = !key_next_stable_w && !wav_btn_stable_w;

    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n)
            rescan_pending_r <= 1'b0;
        else if (rescan_start)
            rescan_pending_r <= 1'b0;
        else if (rescan_request)
            rescan_pending_r <= 1'b1;
    end

    wire auto_tick = (fsm_state == S_SHOW) && auto_en && (auto_cnt == AUTO_PLAY_CYCLES - 1);


    // 分段计数单位为 20ns；重扫真正受理时才开始新一轮测量。
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            boot_meas_stage_r             <= S_IDLE;
            boot_meas_stage_cnt_r         <= 32'd0;
            boot_meas_total_cycles_r      <= 32'd0;
            boot_meas_idle_cycles_r       <= {BOOT_IDLE_COUNT_WIDTH{1'b0}};
            boot_meas_init_cycles_r       <= 32'd0;
            boot_meas_switch_cycles_r     <= 3'd0;
            boot_meas_mount_cycles_r      <= 32'd0;
            boot_meas_scan_cycles_r       <= 32'd0;
            boot_meas_load_first_cycles_r <= 32'd0;
            boot_meas_load_bg_cycles_r    <= 32'd0;
            boot_meas_load_count_r        <= 3'd0;
            boot_meas_first_show_valid_r  <= 1'b0;
        end else if (rescan_start) begin
            boot_meas_stage_r             <= S_INIT;
            boot_meas_stage_cnt_r         <= 32'd1;
            boot_meas_total_cycles_r      <= 32'd0;
            boot_meas_idle_cycles_r       <= {BOOT_IDLE_COUNT_WIDTH{1'b0}};
            boot_meas_init_cycles_r       <= 32'd0;
            boot_meas_switch_cycles_r     <= 3'd0;
            boot_meas_mount_cycles_r      <= 32'd0;
            boot_meas_scan_cycles_r       <= 32'd0;
            boot_meas_load_first_cycles_r <= 32'd0;
            boot_meas_load_bg_cycles_r    <= 32'd0;
            boot_meas_load_count_r        <= 3'd0;
            boot_meas_first_show_valid_r  <= 1'b0;
        end else begin
            if (!boot_meas_first_show_valid_r &&
                boot_meas_total_cycles_r != 32'hffff_ffff)
                boot_meas_total_cycles_r <= boot_meas_total_cycles_r + 32'd1;
            if (!boot_meas_first_show_valid_r && boot_first_loaded_r &&
                boot_first_complete)
                boot_meas_first_show_valid_r <= 1'b1;
            if (fsm_state != boot_meas_stage_r) begin
                case (boot_meas_stage_r)
                    S_IDLE:   boot_meas_idle_cycles_r   <= boot_meas_stage_cnt_r[BOOT_IDLE_COUNT_WIDTH-1:0];
                    S_INIT:   boot_meas_init_cycles_r   <= boot_meas_stage_cnt_r;
                    S_SWITCH: boot_meas_switch_cycles_r <= boot_meas_stage_cnt_r[2:0];
                    S_MOUNT:  boot_meas_mount_cycles_r  <= boot_meas_stage_cnt_r;
                    S_SCAN:   boot_meas_scan_cycles_r   <= boot_meas_stage_cnt_r;
                    S_LOAD: begin
                        if (boot_meas_load_count_r == 3'd0)
                            boot_meas_load_first_cycles_r <= boot_meas_stage_cnt_r;
                        else
                            boot_meas_load_bg_cycles_r <=
                                boot_meas_load_bg_cycles_r + boot_meas_stage_cnt_r;
                        if (boot_meas_load_count_r != 3'd7)
                            boot_meas_load_count_r <= boot_meas_load_count_r + 3'd1;
                    end
                    default: begin end
                endcase
                boot_meas_stage_r     <= fsm_state;
                boot_meas_stage_cnt_r <= 32'd1;
            end else if (boot_meas_stage_cnt_r != 32'hffff_ffff) begin
                boot_meas_stage_cnt_r <= boot_meas_stage_cnt_r + 32'd1;
            end
        end
    end

    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            rescan_active_r   <= 1'b0;
            rescan_complete_r <= 1'b0;
            rescan_done_cnt_r <= 32'd0;
        end else if (rescan_start) begin
            rescan_active_r   <= 1'b1;
            rescan_complete_r <= 1'b0;
            rescan_done_cnt_r <= 32'd0;
        end else if (rescan_active_r && fsm_state == S_FAIL) begin
            rescan_active_r <= 1'b0;
        end else if (rescan_active_r && boot_first_loaded_r && boot_first_complete) begin
            rescan_active_r   <= 1'b0;
            rescan_complete_r <= 1'b1;
            rescan_done_cnt_r <= RESCAN_DONE_HOLD_CYCLES;
        end else if (rescan_complete_r) begin
            if (rescan_done_cnt_r == 32'd0)
                rescan_complete_r <= 1'b0;
            else
                rescan_done_cnt_r <= rescan_done_cnt_r - 32'd1;
        end
    end

    // 027: 自动轮播计时 (behavior_spec §4.4): 仅 S_SHOW 且 auto_en 累计, 其余清零
    // (加载耗时计入轮播间隔的缺陷由"离开 S_SHOW 即清零"排除; auto_en 是计数
    //  必要条件, 到点隐含 auto_en 曾为 1 —— 变异 M4 的单点靶)。
    // [task_036 P3] 图墙移焦点不离开 S_SHOW ⇒ 到点当拍必须自行清零, 否则只命中一次。
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n)
            auto_cnt <= 32'd0;
        else if (auto_tick)
            auto_cnt <= 32'd0;
        else if (fsm_state == S_SHOW && auto_en && view_mode_r == 2'd0)
            auto_cnt <= auto_cnt + 32'd1;
        else
            auto_cnt <= 32'd0;
    end


    // [task_036 P3] B2 长按/短按检测(与上方 C1 检测器同构):
    //   按住: 计数达 CONFIRM_CYCLES 且未触发过 -> b2_long 单拍 + marked 锁存;
    //   松开沿: marked=0(本次未长按过) -> b2_short 单拍; 计数/标记清零。
    //   短按在**松开沿**生效(按下沿时尚不知道这次会不会成为长按)。
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            b2_cnt     <= 32'd0;
            b2_marked  <= 1'b0;
            key_next_d <= 1'b1;
            b2_short_r <= 1'b0;
            b2_long_r  <= 1'b0;
        end else if (boot_metrics_mode || rescan_chord_held || rescan_chord_seen_r || adjust_mode) begin
            b2_cnt     <= 32'd0;
            b2_marked  <= 1'b1;
            key_next_d <= key_next_stable_w;
            b2_short_r <= 1'b0;
            b2_long_r  <= 1'b0;
        end else begin
            b2_short_r <= 1'b0;
            b2_long_r  <= 1'b0;
            key_next_d <= key_next_stable_w;
            if (!key_next_stable_w) begin
                if (b2_cnt < CONFIRM_CYCLES - 1) begin
                    b2_cnt <= b2_cnt + 32'd1;
                end else if (!b2_marked) begin
                    b2_marked <= 1'b1;
                    b2_long_r <= 1'b1;
                end
            end else begin
                b2_cnt    <= 32'd0;
                b2_marked <= 1'b0;
                if (!key_next_d && !b2_marked)
                    b2_short_r <= 1'b1;
            end
        end
    end

    // [task_036 P3] 二级每档停留计时: 仅二级且 S_SHOW 时累计; 换图/换档后重计
    wire view_tick = (fsm_state == S_SHOW) && auto_en && (view_mode_r != 2'd0) &&
                     (step_cnt == VIEW_STEP_CYCLES - 1);
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n)
            step_cnt <= 32'd0;
        else if (!auto_en || fsm_state != S_SHOW || view_mode_r == 2'd0 || step_rst_r || view_tick)
            step_cnt <= 32'd0;
        else
            step_cnt <= step_cnt + 32'd1;
    end

    // [task_036 P3] 槽选择(纯组合):
    //   fill_idx  = 最低号"卡上存在但未就绪"槽(上电预取目标), fill_pend = 存在这样的槽;
    //   first_pres = 最低号存在槽(扫描结束时的初始焦点);
    //   rdy_next / rdy_prev = 从焦点起 +1..+3 / -1..-3 方向首个已就绪槽(无则 = 焦点):
    //   {r,r} 第 i 位 = r[i mod 4]; 右移 cur+1 后第 0/1/2 位 = r[cur+1/+2/+3],
    //   左移 (-cur) mod 4 后第 7/6/5 位 = r[cur-1/-2/-3]。
    wire [3:0] fill_need = slot_present_r & ~slot_ready_r;
    wire       fill_pend = |fill_need;
    wire [1:0] fill_idx  = fill_need[0] ? 2'd0 : fill_need[1] ? 2'd1 :
                           fill_need[2] ? 2'd2 : 2'd3;
    wire [1:0] first_pres = slot_present_r[0] ? 2'd0 : slot_present_r[1] ? 2'd1 :
                            slot_present_r[2] ? 2'd2 : 2'd3;
    wire [1:0] cur_focus = hit_idx_r[1:0];
    wire [7:0] rdy_fwd   = {slot_ready_r, slot_ready_r} >> (cur_focus + 2'd1);
    wire [7:0] rdy_bwd   = {slot_ready_r, slot_ready_r} << (2'd0 - cur_focus);
    wire [1:0] rdy_next  = rdy_fwd[0] ? cur_focus + 2'd1 :
                           rdy_fwd[1] ? cur_focus + 2'd2 :
                           rdy_fwd[2] ? cur_focus + 2'd3 : cur_focus;
    wire [1:0] rdy_prev  = rdy_bwd[7] ? cur_focus - 2'd1 :
                           rdy_bwd[6] ? cur_focus - 2'd2 :
                           rdy_bwd[5] ? cur_focus - 2'd3 : cur_focus;

    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            fsm_state      <= S_IDLE;
            pwr_wait_cnt   <= 27'd0;
            sw_cnt         <= 2'd0;
            query_idx_r    <= 5'd0;
            hit_idx_r      <= 5'd0;
            scan_wait      <= 2'd0;
            fail_code      <= 4'd0;
            sel            <= 1'b0;
            init_start_r   <= 1'b0;
            mount_start_r  <= 1'b0;
            read_start_r   <= 1'b0;
            stream_start_r <= 1'b0;
            load_idx_r     <= 5'd0;         // 027
            slot_present_r <= 4'd0;         // task_036 P3
            slot_ready_r   <= 4'd0;
            slot_w_r       <= 64'd0;
            slot_h_r       <= 64'd0;
            slot_cw_r      <= 64'd0;
            slot_ch_r      <= 64'd0;
            view_mode_r    <= 2'd0;
            display_frame_r<= 2'd0;
            anim_busy      <= 1'b0;
            anim_vf        <= 1'b0;
            anim_k         <= 5'd0;
            anim_exit      <= 1'b0;
            anim_slot      <= 2'd0;
            anim_gear      <= 2'd0;
            step_rst_r     <= 1'b0;
            sel_start_r    <= 1'b0;
            sel_commit_step <= 2'd0;
            sel_commit_seen <= 1'b0;
            fbw_seen        <= 1'b0;
            // [幕布] 五个状态必须显式复位: 未复位时上板为不定值, curt_st≠0 会让
            //   遮罩在开机即生效(全黑或半黑), 不能依赖仿真默认 0。
            curt_st        <= 2'd0;
            curt_dir       <= 1'b0;
            curt_step      <= 5'd0;
            curt_slot      <= 2'd0;
            curt_busy      <= 1'b0;
            curt_wait      <= 4'd0;
            curt_vs_cnt    <= 6'd0;
            boot_first_slot_r      <= 2'd0;
            boot_first_loaded_r    <= 1'b0;
            boot_first_displayed_r <= 1'b0;
            boot_first_fetch_started_r <= 1'b0;
            boot_prefetch_r <= 1'b0;
            boot_frame_request_r <= 1'b0;
        end else begin
            // 必须是首槽的全分辨率取帧；旧帧接受脉冲不能解除后台加载门控。
            if (boot_first_loaded_r && !boot_first_fetch_started_r &&
                fetch_frame_accept && slot_ready_r[boot_first_slot_r] &&
                view_mode_r == 2'd1 && hit_idx_r[1:0] == boot_first_slot_r &&
                boot_frame_complete_w == boot_frame_request_r) begin
                boot_first_fetch_started_r <= 1'b1;
                boot_frame_request_r <= ~boot_frame_request_r;
            end
            if (boot_first_loaded_r && !boot_first_displayed_r && boot_first_complete)
                boot_first_displayed_r <= 1'b1;
            // 单拍脉冲默认清零(case 中可覆盖, 同块后赋值胜出)
            init_start_r   <= 1'b0;
            mount_start_r  <= 1'b0;
            read_start_r   <= 1'b0;
            stream_start_r <= 1'b0;
            step_rst_r     <= 1'b0;
            sel_start_r    <= 1'b0;
            // fb 翻转脉冲粘性捕获: 选择路径最后一次写落盘的脉冲早于 sel_done
            // (SDRAM 落盘先于供流侧计数), 两相提交须捕获已过的脉冲
            if (fb_fwrite_done) fbw_seen <= 1'b1;

            case (fsm_state)
                // 上电稳定等待 100ms(参考完赛工程真卡经验值)后再发 CMD0:
                // 复位释放即发 CMD0 会撞上卡上电未就绪窗口。
                S_IDLE: begin
                    if (pwr_wait_cnt >= PWR_WAIT_TICKS) begin
                        fsm_state    <= S_INIT;
                        init_start_r <= 1'b1;
                    end else begin
                        pwr_wait_cnt <= pwr_wait_cnt + 27'd1;
                    end
                end

                S_INIT: begin
                    if (init_error) begin
                        fail_code <= {1'b0, init_error_code};   // 1/2/3
                        fsm_state <= S_FAIL;
                    end else if (init_done) begin
                        sel        <= 1'b1;                     // §4 S2(与 S3 等待配合)
                        sw_cnt     <= 2'd0;
                        fsm_state  <= S_SWITCH;
                    end
                end

                // §4 S3: sel 置 1 后等待 4 拍(sel 已在 S_INIT 转移拍置位,
                // S_SWITCH 停留 4 拍, mount_start 出现时 sel 已稳定 ≥4 拍)
                S_SWITCH: begin
                    if (sw_cnt == 2'd3)
                        fsm_state <= S_MOUNT;
                    else
                        sw_cnt <= sw_cnt + 2'd1;
                end

                S_MOUNT: begin
                    if (fsm_prev != S_MOUNT)
                        mount_start_r <= 1'b1;      // 首拍发 mount_start
                    else if (mount_done) begin
                        if (mount_error) begin
                            fail_code <= 4'd4;
                            fsm_state <= S_FAIL;
                        end else begin
                            query_idx_r <= 5'd0;
                            scan_wait   <= 2'd0;
                            fsm_state   <= S_SCAN;
                        end
                    end
                end

                // [task_036 P3] 逐索引 0..3 登记存在位(每索引等待 2 拍: query_* 为
                //   1 拍延迟的寄存输出); fat32_lite 只在 query_index < file_count 时刷新
                //   查询结果, 故 index ≥ file_count 一律记为不存在。扫完: 无 PIC ⇒ 码 5;
                //   否则焦点 = 最低号存在槽, 进 S_SHOW 由预取逻辑依次装载。
                S_SCAN: begin
                    if (query_idx_r == 5'd4) begin
                        if (slot_present_r == 4'd0) begin
                            fail_code <= 4'd5;
                            fsm_state <= S_FAIL;
                        end else begin
                            hit_idx_r              <= {3'd0, first_pres};
                            display_frame_r        <= first_pres;
                            boot_first_slot_r      <= first_pres;
                            boot_first_loaded_r    <= 1'b0;
                            boot_first_displayed_r <= 1'b0;
                            boot_first_fetch_started_r <= 1'b0;
                            boot_prefetch_r        <= 1'b1;
                            view_mode_r            <= 2'd1;
                            fsm_state              <= S_SHOW;
                        end
                    end else if (scan_wait != 2'd1) begin
                        scan_wait <= scan_wait + 2'd1;
                    end else begin
                        if ((query_idx_r < file_count) && query_is_bmp_w)
                            slot_present_r[query_idx_r[1:0]] <= 1'b1;
                        query_idx_r <= query_idx_r + 5'd1;
                        scan_wait   <= 2'd0;
                    end
                end

                // read_start 与 loader.stream_start 同拍发出(进入本状态首拍);
                // 错误优先级: read_error(9) > format(6) > size(7) > stream(8)
                // [task_036 P3] 装载文件 load_idx_r 到同号槽; 完成拍登记就绪位与源尺寸
                //      (焦点不随装载移动)。重复进入与首次进入共用 fsm_prev 首拍脉冲模式。
                S_LOAD: begin
                    if (fsm_prev != S_LOAD) begin
                        sel_start_r     <= 1'b1;
                        sel_commit_step <= 2'd0;
                        sel_commit_seen <= 1'b0;
                        fbw_seen        <= 1'b0;
                    end else if (sel_error != 8'd0 && !sel_commit_seen) begin
                        fail_code <= 4'd9;
                        fsm_state <= S_FAIL;
                    end else if (sel_fallback && !sel_start_r && !sel_commit_seen &&
                                 !read_busy && !loader_load_busy) begin
                        read_start_r   <= 1'b1;
                        stream_start_r <= 1'b1;
                        sel_commit_seen <= 1'b1;
                    end else if (sel_done && sel_commit_step == 2'd0) begin
                        sel_commit_step <= 2'd1;
                    end else if ((fb_fwrite_done || fbw_seen) && sel_commit_step == 2'd1) begin
                        sel_commit_seen <= 1'b1;
                        slot_ready_r[load_idx_r[1:0]] <= 1'b1;
                        slot_w_r[{load_idx_r[1:0], 4'd0} +: 16] <= sel_src_w;
                        slot_h_r[{load_idx_r[1:0], 4'd0} +: 16] <= sel_src_h;
                        slot_cw_r[{load_idx_r[1:0], 4'd0} +: 16] <= sel_cw;
                        slot_ch_r[{load_idx_r[1:0], 4'd0} +: 16] <= sel_ch;
                        if (load_idx_r[1:0] == boot_first_slot_r) begin
                            boot_first_loaded_r <= 1'b1;
                            display_frame_r     <= load_idx_r[1:0];
                        end
                        fsm_state <= S_SHOW;
                    end else if (read_done && read_error) begin
                        fail_code <= 4'd9;
                        fsm_state <= S_FAIL;
                    end else if (loader_fmt_err) begin
                        fail_code <= 4'd6;
                        fsm_state <= S_FAIL;
                    end else if (loader_sz_err) begin
                        fail_code <= 4'd7;
                        fsm_state <= S_FAIL;
                    end else if (loader_strm_err) begin
                        fail_code <= 4'd8;
                        fsm_state <= S_FAIL;
                    end else if (loader_load_done) begin
                        slot_ready_r[load_idx_r[1:0]] <= 1'b1;
                        slot_w_r[{load_idx_r[1:0], 4'd0} +: 16] <= loader_src_w;
                        slot_h_r[{load_idx_r[1:0], 4'd0} +: 16] <= loader_src_h;
                        // [task_037 P-C] 本帧 resampler 几何实际值(几何相早已完成,
                        //   与源尺寸同为帧级准静态; 二级字幕的内容尺寸以此为准)
                        slot_cw_r[{load_idx_r[1:0], 4'd0} +: 16] <= loader_cw_w;
                        slot_ch_r[{load_idx_r[1:0], 4'd0} +: 16] <= loader_ch_w;
                        if (load_idx_r[1:0] == boot_first_slot_r) begin
                            boot_first_loaded_r <= 1'b1;
                            display_frame_r     <= load_idx_r[1:0];
                        end
                        fsm_state <= S_SHOW;
                    end
                end

                // 027: S_SHOW 事件驱动; 事件仅在 S_SHOW 采样, S_LOAD 期间按键忽略
                // (方案 A, 防连跳天然保证); 下一格/下一张优先于上一格/上一张。
                // [task_036 P3] 优先级: 预取装载 > 按键/计时。
                //   图墙: B2 短按/轮播到点 = 焦点 +1 格; C1 长按 = 焦点 −1 格(四格循环,
                //         含未就绪格); B2 长按 = 焦点槽已就绪则进入二级 ÷1。
                //   二级: B2 短按 / (轮播开 ∧ ÷4 档到点) = 下一张已就绪图(回到 ÷1);
                //         C1 长按 = 上一张已就绪图; 其余到点 = 下一档; B2 长按 = 回图墙。
                //   只在已就绪槽之间切换 ⇒ 不启动任何 SD 读; display_frame 跟随焦点,
                //   由帧缓冲在 vsync 拍生效。装载目标恒为未就绪槽; 预取前先把
                //   display_frame 指向别的槽, 待帧缓冲在 vsync 拍把 active_frame 移开
                //   (≤ 1 帧)才开始装载 ⇒ 写槽 ≠ active_frame 由构造保证。
                //   另须等 fat32_lite 与 loader 都回到空闲: loader 收齐像素即报 load_done,
                //   而文件流器还要再读一扇区做 FAT 链尾核对(≈0.4 ms)才退出读态 ——
                //   此间发出的 read_start 会被 fat32_lite 忽略, loader 则空等数据。
                S_SHOW: begin
                    if (rescan_start) begin
                        sel             <= 1'b0;
                        sw_cnt          <= 2'd0;
                        query_idx_r     <= 5'd0;
                        hit_idx_r       <= 5'd0;
                        scan_wait       <= 2'd0;
                        load_idx_r      <= 5'd0;
                        slot_present_r  <= 4'd0;
                        slot_ready_r    <= 4'd0;
                        slot_w_r        <= 64'd0;
                        slot_h_r        <= 64'd0;
                        slot_cw_r       <= 64'd0;
                        slot_ch_r       <= 64'd0;
                        display_frame_r <= 2'd0;
                        boot_first_slot_r      <= 2'd0;
                        boot_first_loaded_r    <= 1'b0;
                        boot_first_displayed_r <= 1'b0;
                        boot_first_fetch_started_r <= 1'b0;
                        boot_prefetch_r <= 1'b0;
                        view_mode_r     <= 2'd0;
                        sel_start_r     <= 1'b0;
                        sel_commit_step <= 2'd0;
                        sel_commit_seen <= 1'b0;
                        fbw_seen        <= 1'b0;
                        fail_code       <= 4'd0;
                        fsm_state       <= S_INIT;
                        init_start_r    <= 1'b1;
                    end else if (rescan_request) begin
                        // Request is latched; consume the long-press event while
                        // current SD transactions drain before rescan_start.
                    end else if (anim_busy && vs_start_pulse) begin
                        // [P2b] 动画帧推进与原子提交(k30 帧由正常通路渲染)
                        if (anim_commit) begin
                            anim_busy <= 1'b0;
                            anim_vf   <= 1'b0;
                            anim_k    <= 5'd0;
                            if (anim_class) begin
                                // [C 类] 提交: 图墙"内"换图/换档收尾
                                view_mode_r <= anim_c_sel ? anim_c_gear : 2'd1;
                                if (!anim_c_sel) begin
                                    // C1 异图擦除: 焦点/显示槽落到新图
                                    display_frame_r <= anim_slot;
                                    hit_idx_r       <= {3'd0, anim_slot};
                                end
                                step_rst_r <= 1'b1;
                            end else if (!anim_exit) begin
                                view_mode_r     <= 2'd1;
                                display_frame_r <= anim_slot;
                                hit_idx_r       <= {3'd0, anim_slot};
                                step_rst_r      <= 1'b1;
                            end else begin
                                view_mode_r     <= 2'd0;
                            end
                        end else begin
                            anim_k  <= anim_k + 5'd1;
                            anim_vf <= 1'b1;
                            // [A 类收尾闪错图修复 2026-09-27] 统一提交: display_frame_r
                            //   在 commit 前一帧(anim_k==28)预写目标槽。否则 commit 沿
                            //   fb 同沿采 display_frame_r 旧值(active_frame 慢一帧), 而
                            //   满屏路径 vm_focus=fb_active_frame ⇒ 首次静态满屏先显示
                            //   旧槽一帧(f32 异图闪现)。预写后 commit 沿 fb 即采到目标槽,
                            //   视图/槽原子交接。A 类动画期 view_v=0 不读 fb, 预写无副作用;
                            //   仅 A 类进入需要(C1 触发时已预写, 退出回墙不写 display_frame)。
                            if (!anim_class && !anim_exit && (anim_k == 6'd28)) begin
                                display_frame_r <= anim_slot;
                            end
                        end
                    end else if (anim_busy) begin
                        // 动画期吸收一切导航(无队列); 装载延后
                    end else if (curt_busy) begin
                        // [幕布 FSM] 步进只绑视频帧边界(vs_start_pulse), 与 view_v/focus_v
                        //   同域同拍。禁止绑 FE 的"接受新帧": 取数长时间收不完一帧时, 绑它
                        //   会让状态机永久停在 st2(全黑)且 curt_busy 常驻 ⇒ 吸收全部按键、
                        //   屏幕死黑且不可恢复(2026-09-29 上板实测)。欠载跨帧改幕高最坏只是
                        //   一帧内黑带高度不齐(外观), 优先级低于死锁。
                        if (vs_start_pulse) begin
                            if (curt_st == 2'd1) begin                 // 合拢
                                if (curt_step == CURT_STEPS[4:0] - 5'd1) begin
                                    curt_st   <= 2'd2;
                                    curt_step <= 5'd0;
                                    curt_wait <= 4'd0;
                                    // [E2 统一提交复用] 全黑交接第一帧预写目标槽(E2 原子
                                    //   交接教训: display_frame 与视图同事务消费 next-state)
                                    if (!curt_dir) begin
                                        display_frame_r <= curt_slot;
                                    end
                                end else begin
                                    curt_step <= curt_step + 5'd1;
                                end
                            end else if (curt_st == 2'd2) begin        // 全黑交接
                                // 交接以"视图/槽一致"为准(curt_handover_ok), 但该等待必须有界:
                                //   条件长期不成立时仍要翻面收摊, 否则全黑 + curt_busy 常驻
                                //   (吸收全部按键)不可恢复。
                                if (curt_handover_ok || (curt_wait >= CURT_WAIT_MAX)) begin
                                    if (curt_dir) begin
                                        view_mode_r <= 2'd0;           // 退出→图墙(焦点保留)
                                    end else begin
                                        view_mode_r <= 2'd1;           // 进入→满屏 ÷1
                                        hit_idx_r   <= {3'd0, curt_slot};
                                        step_rst_r  <= 1'b1;
                                    end
                                    curt_st   <= 2'd3;
                                    curt_step <= 5'd0;
                                end else if (curt_wait != 4'hF) begin
                                    curt_wait <= curt_wait + 4'd1;
                                end
                            end else if (curt_st == 2'd3) begin        // 展开
                                if (curt_step == CURT_STEPS[4:0] - 5'd1) begin
                                    curt_st   <= 2'd0;
                                    curt_step <= 5'd0;
                                    curt_busy <= 1'b0;
                                end else begin
                                    curt_step <= curt_step + 5'd1;
                                end
                            end
                            // 总时长看门狗(名义 8+1+8=17 帧): 超上限一律收摊, 使 curt_busy
                            //   无法常驻 ⇒ 任何阶段异常最坏退化成"硬翻面", 屏幕与按键可恢复。
                            if (curt_vs_cnt >= CURT_WATCHDOG) begin
                                curt_st     <= 2'd0;
                                curt_step   <= 5'd0;
                                curt_busy   <= 1'b0;
                                curt_vs_cnt <= 6'd0;
                                if (!curt_dir) begin                   // 收摊时仍未翻面则补翻面
                                    view_mode_r <= 2'd1;
                                    hit_idx_r   <= {3'd0, curt_slot};
                                end
                            end else begin
                                curt_vs_cnt <= curt_vs_cnt + 6'd1;
                            end
                        end
                    end else if (fill_pend && !rescan_pending_r && !rescan_request &&
                                         (!boot_first_loaded_r || boot_first_displayed_r)) begin
                        display_frame_r <= boot_first_loaded_r ? boot_first_slot_r : (fill_idx ^ 2'd1);
                        if (fb_active_frame != fill_idx && !read_busy && !loader_load_busy) begin
                            load_idx_r <= {3'd0, fill_idx};
                            fsm_state  <= S_LOAD;
                        end
                    end else if (rescan_pending_r || rescan_chord_held || rescan_chord_seen_r || adjust_mode ||
                                 (boot_prefetch_r && (!boot_first_displayed_r || fill_pend))) begin
                        // 首图完整呈现前及后台预取期间不启动导航动画。
                        step_rst_r <= 1'b1;
                    end else if (boot_prefetch_r && boot_first_displayed_r && !fill_pend) begin
                        boot_prefetch_r <= 1'b0;
                        view_mode_r <= 2'd0;
                    end else if (view_mode_r == 2'd0) begin
                        if (b2_short_r || auto_tick) begin
                            hit_idx_r <= next_index_of(hit_idx_r);
                        end else if (prev_press_r && !rescan_chord_seen_r) begin
                            hit_idx_r <= prev_index_of(hit_idx_r);
                        end else if (b2_long_r && slot_ready_r[cur_focus]) begin
                            // [幕布] 进入: 启动合拢(替代 A 类缩放; A 类实验停用默认关)
                            //   目标槽已就绪才启动(用户规格4); 合拢后全黑交接→展开到 ÷1 满屏
                            curt_busy  <= 1'b1;
                            curt_st    <= 2'd1;
                            curt_dir   <= 1'b0;
                            curt_slot  <= cur_focus;
                            curt_step  <= 5'd0;
                            curt_wait  <= 4'd0;
                            curt_vs_cnt<= 6'd0;
                        end
                    end else begin
                        if (b2_long_r) begin
                            // [幕布] 退出: 启动合拢; 全黑交接后展开回图墙(保留原焦点)
                            curt_busy  <= 1'b1;
                            curt_st    <= 2'd1;
                            curt_dir   <= 1'b1;
                            curt_slot  <= hit_idx_r[1:0];
                            curt_step  <= 5'd0;
                            curt_wait  <= 4'd0;
                            curt_vs_cnt<= 6'd0;
                        end else if (b2_short_r || (view_tick && view_mode_r == 2'd3 && auto_en)) begin
                            // [C1] 异图擦除(下一张=下→上滑入; 方向对调 2026-09-27): 启动 C 类动画
                            anim_busy   <= 1'b1;
                            anim_class  <= 1'b1;
                            anim_c_sel  <= 1'b0;
                            anim_c_dir  <= 2'd1;
                            anim_c_src  <= fb_active_frame;
                            anim_slot   <= rdy_next;
                            anim_k      <= 5'd1;
                            anim_vf     <= 1'b0;
                            display_frame_r <= rdy_next;
                        end else if (prev_press_r && !rescan_chord_seen_r) begin
                            // [C1] 异图擦除(上一张=上→下滑入; 方向对调)
                            anim_busy   <= 1'b1;
                            anim_class  <= 1'b1;
                            anim_c_sel  <= 1'b0;
                            anim_c_dir  <= 2'd0;
                            anim_c_src  <= fb_active_frame;
                            anim_slot   <= rdy_prev;
                            anim_k      <= 5'd1;
                            anim_vf     <= 1'b0;
                            display_frame_r <= rdy_prev;
                        end else if (view_tick) begin
                            // [C2] 同图异档溶解(高→低 ÷1→÷2→÷4): 槽不变, 仅换 block
                            anim_busy   <= 1'b1;
                            anim_class  <= 1'b1;
                            anim_c_sel  <= 1'b1;
                            anim_c_src  <= fb_active_frame;
                            anim_slot   <= fb_active_frame;
                            anim_c_gear <= (view_mode_r == 2'd3) ? 2'd1 : view_mode_r + 2'd1;
                            anim_k      <= 5'd1;
                            anim_vf     <= 1'b0;
                        end
                    end
                end

                S_FAIL: begin
                    if (rescan_start) begin
                        sel             <= 1'b0;
                        sw_cnt          <= 2'd0;
                        query_idx_r     <= 5'd0;
                        hit_idx_r       <= 5'd0;
                        scan_wait       <= 2'd0;
                        load_idx_r      <= 5'd0;
                        slot_present_r  <= 4'd0;
                        slot_ready_r    <= 4'd0;
                        slot_w_r        <= 64'd0;
                        slot_h_r        <= 64'd0;
                        slot_cw_r       <= 64'd0;
                        slot_ch_r       <= 64'd0;
                        display_frame_r <= 2'd0;
                        boot_first_slot_r      <= 2'd0;
                        boot_first_loaded_r    <= 1'b0;
                        boot_first_displayed_r <= 1'b0;
                        boot_first_fetch_started_r <= 1'b0;
                        boot_prefetch_r <= 1'b0;
                        view_mode_r     <= 2'd0;
                        sel_start_r     <= 1'b0;
                        sel_commit_step <= 2'd0;
                        sel_commit_seen <= 1'b0;
                        fbw_seen        <= 1'b0;
                        fail_code       <= 4'd0;
                        fsm_state       <= S_INIT;
                        init_start_r    <= 1'b1;
                    end else begin
                        fsm_state <= S_FAIL;
                    end
                end

                default: fsm_state <= S_IDLE;
            endcase
        end
    end

    // fsm_prev: fsm_state 上一拍值(S_MOUNT/S_LOAD 首拍脉冲的生成依据)
    reg [3:0] fsm_prev;
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) fsm_prev <= S_IDLE;
        else             fsm_prev <= fsm_state;
    end

    // S_INIT 首拍的 init_start: 由 S_IDLE 转移拍置位(见上方 S_IDLE 分支),
    // 无需 fsm_prev。S_MOUNT/S_LOAD 首拍脉冲依赖 fsm_prev 比较, 两段 always
    // 的读写交错: fsm_prev 在本拍更新为上一拍 state, 与 case 中判断一致。

    // --------------------------------------------------------------------
    // LED 状态契约 (§7)
    //   慢闪 ~1Hz: 半周期 25M 拍(0.5s) @50MHz; 快闪 ~2Hz: 半周期 12.5M 拍。
    // --------------------------------------------------------------------
    wire [24:0] led_half = (fsm_state == S_FAIL) ? LED_HALF_FAST
                                                 : LED_HALF_SLOW;
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            led_cnt <= 25'd0;
            led_tgl <= 1'b0;
        end else if (led_cnt >= led_half) begin
            led_cnt <= 25'd0;
            led_tgl <= ~led_tgl;
        end else begin
            led_cnt <= led_cnt + 25'd1;
        end
    end

    // 027 LED 契约(INTERFACE_SPEC §4.4): S_SHOW=当前编号常亮, S_LOAD=编号慢闪。
    // pic_num = hit_idx_r[1:0]+1 ∈ 1..4([1:0] 截位安全性见 behavior_spec §4.3);
    // [task_036 P3] hit_idx_r = 焦点(图墙焦点格 / 二级当前图), 预取装载期间慢闪焦点编号。
    wire [3:0] pic_num = {2'b00, hit_idx_r[1:0]} + 4'd1;
    reg [3:0] led_live;
    always @* begin
        if (fsm_state == S_FAIL)
            led_live = led_tgl ? fail_code : 4'b0000;
        else if (rescan_active_r || rescan_pending_r)
            led_live = led_tgl ? 4'b1110 : 4'b0000;
        else if (rescan_complete_r)
            led_live = 4'b1111;
        else if (fsm_state == S_LOAD)
            led_live = led_tgl ? pic_num : 4'b0000;      // 027: 编号慢闪(加载中)
        else if (fsm_state == S_SHOW)
            led_live = pic_num;                          // 027: 编号常亮
        else if (fsm_state == S_SCAN)
            led_live = 4'b0111;
        else if (fsm_state == S_MOUNT || fsm_state == S_SWITCH)
            led_live = 4'b0001;                          // init_done 指示(022 原样)
        else
            led_live = 4'b0000;                          // S_IDLE / S_INIT
    end
    reg [3:0] boot_metrics_phase_r;
    reg [31:0] boot_metrics_snapshot_r;
    reg [31:0] boot_metrics_value;
    (* async_reg = "true", preserve = "true" *) reg [3:0] boot_metrics_sw_meta_r;
    (* async_reg = "true", preserve = "true" *) reg [3:0] boot_metrics_sw_code_r;
    // 仅观测页码编码/解码，所有16个值保持；两级同步级数和复位值不变。
    wire [3:0] boot_metrics_sw_sync_r = {
        boot_metrics_sw_code_r[3] ^ boot_metrics_sw_code_r[0],
        boot_metrics_sw_code_r[2] ^ boot_metrics_sw_code_r[3] ^ boot_metrics_sw_code_r[0],
        boot_metrics_sw_code_r[1] ^ boot_metrics_sw_code_r[2] ^ boot_metrics_sw_code_r[3] ^ boot_metrics_sw_code_r[0],
        boot_metrics_sw_code_r[1] ^ boot_metrics_sw_code_r[2] ^ boot_metrics_sw_code_r[3]};
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            boot_metrics_sw_meta_r <= 4'd0;
            boot_metrics_sw_code_r <= 4'd0;
        end else begin
            boot_metrics_sw_meta_r <= {sw[0] ^ sw[1] ^ sw[3],
                                       sw[2] ^ sw[3], sw[1] ^ sw[2], sw[0] ^ sw[1]};
            boot_metrics_sw_code_r <= boot_metrics_sw_meta_r;
        end
    end
    always @* begin
        case (boot_metrics_sw_sync_r)
            4'd0: boot_metrics_value = boot_meas_total_cycles_r;
            4'd1: boot_metrics_value = {{(32-BOOT_IDLE_COUNT_WIDTH){1'b0}}, boot_meas_idle_cycles_r};
            4'd2: boot_metrics_value = boot_meas_init_cycles_r;
            4'd3: boot_metrics_value = {29'd0, boot_meas_switch_cycles_r};
            4'd4: boot_metrics_value = boot_meas_mount_cycles_r;
            4'd5: boot_metrics_value = boot_meas_scan_cycles_r;
            4'd6: boot_metrics_value = boot_meas_load_first_cycles_r;
            4'd7: boot_metrics_value = boot_meas_load_bg_cycles_r;
            4'd8: boot_metrics_value = boot_meas_total_cycles_r;
            // 页10只读诊断：状态/原始键/消抖键/重扫标志/时钟复位。
            4'd10: boot_metrics_value = {
                fsm_state, rst_n, key_next, key_wav, key_auto,
                key_next_stable_w, wav_btn_stable_w, key_auto_stable_w, rescan_armed_r,
                rescan_pending_r, rescan_active_r, rescan_start, rescan_request,
                rescan_chord_seen_r, rescan_press_r, long_press_marked, adjust_mode,
                pll1_locked, pll2_locked, core_rst_n, rst_pixel, 8'd0};
            default: boot_metrics_value = {24'd0, fsm_state, boot_meas_first_show_valid_r,
                                          boot_meas_load_count_r};
        endcase
    end
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            boot_metrics_phase_r <= 4'd0;
            boot_metrics_snapshot_r <= 32'd0;
        end else if (!boot_metrics_mode) begin
            boot_metrics_phase_r <= 4'd0;
        end else if (led_cnt >= led_half) begin
            if (boot_metrics_phase_r == 4'd0)
                boot_metrics_snapshot_r <= boot_metrics_value;
            else if (boot_metrics_phase_r >= 4'd2)
                boot_metrics_snapshot_r <= {boot_metrics_snapshot_r[27:0], 4'd0};
            boot_metrics_phase_r <= (boot_metrics_phase_r == 4'd9) ? 4'd0 :
                                   boot_metrics_phase_r + 4'd1;
        end
    end
    assign led = !boot_metrics_mode ? led_live :
                 (boot_metrics_phase_r == 4'd0) ? 4'hf :
                 (boot_metrics_phase_r == 4'd1) ? 4'h0 : boot_metrics_snapshot_r[31:28];

    // --------------------------------------------------------------------
    // 显示链 (§6; [task_036 P3] 取数 → 映射 → 寄存一级 → 帧缓冲流式读口)
    // --------------------------------------------------------------------
    // 视图参数/焦点/就绪位在 vs_start_pulse 拍锁存(与取数引擎起帧、帧缓冲
    // active_frame 生效同拍) ⇒ 一帧内映射恒定, 帧间切换无撕裂。
    reg  [1:0]  view_v;
    reg  [1:0]  focus_v;
    reg  [3:0]  ready_v;
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            view_v  <= 2'd0;
            focus_v <= 2'd0;
            ready_v <= 4'd0;
        end else if (vs_start_pulse) begin
            // [P2b] 动画帧: mapper 走墙背景语义(view0, focus=动画槽);
            //   提交拍按提交结果锁存(提交帧由正常通路渲染, 逐位衔接)
            if (anim_commit) begin
                // [C 类] 提交帧与正常通路衔接: C1→÷1 新槽, C2→目标档同槽
                if (anim_class) begin
                    view_v  <= anim_c_sel ? anim_c_gear : 2'd1;
                    focus_v <= anim_slot;
                end else begin
                    view_v  <= anim_exit ? 2'd0 : 2'd1;
                    focus_v <= anim_slot;
                end
            end else if (anim_busy && !anim_class) begin
                view_v  <= 2'd0;          // A 类动画帧 mapper 强制墙背景
                focus_v <= anim_slot;
            end else if (anim_busy) begin
                // C 类期间: mapper 输出被 c_wipe 旁路, 这里仅保持无害值
                view_v  <= 2'd1;
                focus_v <= anim_slot;
            end else begin
                view_v  <= view_mode_r;
                focus_v <= hit_idx_r[1:0];
            end
            ready_v <= slot_ready_r;
        end
    end

    // 四种模式的窗口矩形与缩放参数(映射闭式见 view_mapper.v):
    //   图墙 = 320×240 格、2× 放大、2×2 抽稀块; 二级 = 640×480 单格, ÷k 即 k×k 抽稀块
    wire        vm_wall   = (view_v == 2'd0);
    wire [11:0] vm_rect_w = vm_wall ? 12'd320 : 12'd640;
    wire [11:0] vm_rect_h = vm_wall ? 12'd240 : 12'd480;
    wire [3:0]  vm_blk    = vm_wall ? 4'd1 : {2'b00, view_v} - 4'd1;
    wire [3:0]  vm_scl    = vm_wall ? 4'd1 : 4'd0;
    // 二级读的槽取帧缓冲 active_frame(与 display_frame 在同一 vsync 拍生效)
    wire [1:0]  vm_focus  = vm_wall ? focus_v : fb_active_frame;

    wire        vm_rd_en, vm_border, vm_pad;
    wire [1:0]  vm_slot;
    wire [9:0]  vm_x, vm_y;

    view_mapper #(
        .SEP_PX (2)
    ) u_vmap (
        .in_de      (1'b1),
        .pixel_x    (fe_pos_x),
        .pixel_y    (fe_pos_y),
        .view_mode  (view_v),
        .focus_slot (vm_focus),
        .slot_ready (ready_v),
        .rect_x     (12'd0),
        .rect_y     (12'd0),
        .rect_w     (vm_rect_w),
        .rect_h     (vm_rect_h),
        .block_log2 (vm_blk),
        .scale_log2 (vm_scl),
        .rd_en      (vm_rd_en),
        .rd_slot    (vm_slot),
        .rd_x       (vm_x),
        .rd_y       (vm_y),
        .border_en  (vm_border),
        .pad_en     (vm_pad)
    );

    // ------------------------------------------------------------------
    // [C 类 2026-09-27] c_wipe 图墙内转场合成器(异图擦除推拉 / 同图异档溶解)
    //   纯组合, 逐显示像素给唯一源; C2 的 block 由当前档位/目标档换算。
    // ------------------------------------------------------------------
    wire [3:0] c_old_blk = {2'b00, view_v} - 4'd1;            // 当前档 block_log2
    wire [3:0] c_new_blk = {2'b00, anim_c_gear} - 4'd1;       // 目标档 block_log2

    // [C1 整张滑入滑出 2026-09-27] 新图整张从进入边滑入、旧图原位被盖, 无压缩 ⇒
    //   c_wipe 内部纯加减, 不再需要 step 查表(原 step 逻辑随滑入模型整体移除)。

    wire        cw_en;
    wire [1:0]  cw_slot;
    wire [9:0]  cw_x, cw_y;
    c_wipe u_cwipe (
        .px          ({2'b00, fe_pos_x[9:0]}),
        .py          ({2'b00, fe_pos_y[9:0]}),
        .k           (anim_k),
        .anim_c_sel  (anim_c_sel),
        .anim_c_dir  (anim_c_dir),
        .c_src_slot  (anim_c_src),
        .c_dst_slot  (anim_slot),
        .c_old_blk   (c_old_blk),
        .c_new_blk   (c_new_blk),
        .rd_en       (cw_en),
        .rd_slot     (cw_slot),
        .rd_x        (cw_x),
        .rd_y        (cw_y)
    );

    // ------------------------------------------------------------------
    // [P2b] nn_scaler(A 类动画 rect 源坐标) + 合成 mux
    //   动画帧: rect 内像素 = scaler 输出(slot=动画槽, en=1, tag=图像);
    //           其余像素 = mapper 墙背景(view_v 已在动画期强制 view0)。
    //   scaler 与流水同拍推进(up_rdy=fe_pos_take; 停顿拍坐标保持)。
    //   首末衔接: k0 帧由正常通路渲染(触发帧不合成), k30 提交帧同理。
    // ------------------------------------------------------------------
    wire        nsc_rsp_v, nsc_rsp_in;
    wire [1:0]  nsc_slot;
    wire [9:0]  nsc_px, nsc_py;
    wire [11:0] nsc_w, nsc_h, nsc_gx, nsc_gy;
    wire [13:0] nsc_S;
    nn_scaler u_nscale (
        .clk          (ctrl_clk),
        .rst_n        (core_rst_n),
        // [A1 帧同步] frame_start 改接 FE 的 fetch_frame_accept(欠载跨帧忽略 VS 时
        //   scaler 帧首不被物理 VS 推进, 与取数帧严格同步); 原 anim 条件保留
        .frame_start  (fetch_frame_accept && anim_busy && !anim_class),  // C 类不走 scaler
        .k_in         (anim_k[4:0]),  // A 类 k≤29, 显式取低 5 位(消除位宽告警)
        .dir_exit     (anim_exit),
        .gear         (anim_gear),
        .slot         (anim_slot),
        .req_v        (fe_pos_valid),
        .req_px       (fe_pos_x),
        .req_py       (fe_pos_y),
        .up_rdy       (fe_pos_take),
        .req_rdy      (),
        .rsp_v        (nsc_rsp_v),
        .rsp_in       (nsc_rsp_in),
        .rsp_slot     (nsc_slot),
        .rsp_x        (nsc_px),
        .rsp_y        (nsc_py),
        .geo_w        (nsc_w),
        .geo_h        (nsc_h),
        .geo_x        (nsc_gx),
        .geo_y        (nsc_gy),
        .geo_S        (nsc_S)
    );

    // 合成源选择: A 类动画帧 = nn_scaler(rect 内); C 类动画帧 = c_wipe(满屏);
    //   普通帧 = view_mapper。优先级 C > A > mapper。
    wire        comp_c    = anim_vf && anim_class;                 // C 类动画帧
    wire        comp_nsc  = anim_vf && !anim_class && nsc_rsp_in;  // A 类 rect 内
    wire        comp_en   = comp_c   ? cw_en   :
                            anim_vf  ? (comp_nsc ? 1'b1 : vm_rd_en) : vm_rd_en;
    wire [1:0]  comp_slot = comp_c   ? cw_slot   : (comp_nsc ? nsc_slot : vm_slot);
    wire [9:0]  comp_x    = comp_c   ? cw_x      : (comp_nsc ? nsc_px   : vm_x);
    wire [9:0]  comp_y    = comp_c   ? cw_y      : (comp_nsc ? nsc_py   : vm_y);
    wire [1:0]  comp_tag  = (comp_c || comp_nsc) ? 2'b00 : {vm_border, vm_pad};

    // [幕布遮罩 2026-09-29] 幕布覆盖的显示行改出 en=0 / tag=00 的黑响应(与墙分隔带
    //   同色)。遮罩放在合成器输出口, 不改取数侧: 被遮像素仍按其屏幕位置产生恰好
    //   一个按序请求与响应(FE 每帧仍收满 307200 个响应 ⇒ 位置守恒)。
    wire        curt_mask;
    curtain_wipe u_curtain (
        .py          (fe_pos_y),
        .curt_active (curt_active),
        .curt_h      (curt_h),
        .in_curt     (curt_mask)
    );
    wire        comp_en_m  = curt_mask ? 1'b0  : comp_en;
    wire [1:0]  comp_tag_m = curt_mask ? 2'b00 : comp_tag;

    // 映射结果寄存一级(有且仅有一级): 切断 映射器 → 帧缓冲行缓存命中判定/地址计算
    //   的组合链。本级在"FE 交出坐标"或"本级被下游消费"时更新; 背压期间载荷保持。
    //   随路标签 {边框, 占位} 由响应原样带回给取数引擎着色。
    //   [P2b v2.1] vm_q_full: 该请求来自缩放路径(需全宽覆盖)的侧带, 与请求
    //   同拍装入, 供 line_supply 覆盖位命中守卫使用。
    wire        vm_q_acc = vm_q_v && fb_req_ready_c;
    // 本级只由两个事件推进: FE 交出当前坐标(fe_pos_take), 或本级被下游消费(vm_q_acc)。
    //   缺后者 ⇒ 已被下游收走的请求滞留在本级, 下一拍被再收一次(响应重复);
    //   缺前者(按 !vm_q_v 装载)⇒ 装入未被 FE 接受的坐标, 同一坐标交出两次(响应错位)。
    //   en=0(占位/边框/幕布黑)自应答: 本级为空时即使 fb 未就绪也交出该坐标, 入级后仍
    //     等下游消费 ⇒ 图像装载期与幕布遮罩都不被 ready 卡死, 且请求不丢。
    //   契约看护: tb/tb_vm_q_handshake.v(构建时抽取本级源码)。
    assign      fe_pos_take = fe_pos_valid &&
                              (vm_q_acc || (!vm_q_v && (fb_req_ready_c || !comp_en_m)));
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            vm_q_v    <= 1'b0;
            vm_q_en   <= 1'b0;
            vm_q_slot <= 2'd0;
            vm_q_tag  <= 2'd0;
            vm_q_x    <= 10'd0;
            vm_q_y    <= 10'd0;
            vm_q_full <= 1'b0;
        end else if (fe_pos_take || vm_q_acc) begin
            vm_q_v <= fe_pos_valid;
            if (fe_pos_valid) begin
                vm_q_en   <= comp_en_m;
                vm_q_slot <= comp_slot;
                vm_q_tag  <= comp_tag_m;
                vm_q_x    <= comp_x;
                vm_q_y    <= comp_y;
                vm_q_full <= comp_nsc;
            end
        end
    end

    // ====================================================================
    // [task_043 P1] line_supply 供数观测平面
    //   vm_q 与帧缓冲读口之间的组合直通 + 协议观测: 1:1 在途追踪、帧提交点
    //   排空检查、源坐标越界捕获、最长无响应、(slot,y) 驻留登记。
    //   P1 策略 = 直通(与基线逐拍一致); P2b 起供数策略在本模块内演进。
    // ====================================================================
    line_supply #(
        // [E1 WAYS=5 证伪后回退] 回 WAYS=4(缩放 2 路+墙 2 路); 保留 QDEPTH=32。
        //   WAYS=5 实验无改善且引入 hdrop 回归(证据 archive_e1_ways5_20260927/),
        //   按"停止加路"回退。QDEPTH=32 保留(队列加深无负面影响)。
        .WAYS (4)                                        // [回退] 缩放 2 路 + 墙 2 路
    ) u_line_supply (
        .clk           (ctrl_clk),
        .rst_n         (core_rst_n),
        // [A1 帧同步] frame_start 改接 FE 的 fetch_frame_accept(与取数帧严格同步,
        //   欠载跨帧忽略 VS 时 hint 游走/bank 驻留不被物理 VS 重同步)
        .frame_start   (fetch_frame_accept),
        // [P2b v2.1] 消费侧 bank 服务 = A 类动画帧(anim_vf 且非 C 类); 填充预取 = A 类动画
        //   (pending 期即可经 fb 口预取, 端口仲裁消费者严格优先)
        //   [C 类] 图墙内转场走直通档(anim_v=0): 每显示行源行数=1, 与基线二级一致,
        //           bank 架构不参与 ⇒ A 类结构性瓶颈(FB 2 路行缓存 vs 每行 3 源行)整体绕开。
        .anim_v        (anim_vf && !anim_class),
        .hint_en       (anim_busy && !anim_class),
        .hint_v        (ls_hint_v),
        .hint_rdy      (ls_hint_rdy),
        .hint_s        (ls_hint_s),
        .hint_y        (ls_hint_y),
        .hint_k        (ls_hint_k),
        .row_covered_o (ls_row_covered),
        .q_occ_o       (ls_q_occ),
        .cq_v          (vm_q_v),
        .cq_rdy        (fb_req_ready_c),
        .cq_en         (vm_q_en),
        .cq_slot       (vm_q_slot),
        .cq_x          ({1'b0, vm_q_x}),
        .cq_y          (vm_q_y),
        .cq_tag        (vm_q_tag),
        .cq_full       (vm_q_full),
        .sq_v          (sq_v),
        .sq_en         (sq_en),
        .sq_data       (sq_data),
        .sq_tag        (sq_tag),
        .fq_v          (fb_req_valid),
        .fq_rdy        (fb_req_ready),
        .fq_en         (fb_req_en),
        .fq_slot       (fb_req_slot),
        .fq_x          (fb_req_x),
        .fq_y          (fb_req_y),
        .fq_tag        (fb_req_tag),
        .fs_v          (fb_rsp_valid),
        .fs_en         (fb_rsp_en),
        .fs_data       (fb_rsp_data),
        .fs_w32        (fb_rsp_w32),
        .fs_tag        (fb_rsp_tag),
        .cnt_req       (ls_cnt_req),
        .cnt_rsp       (ls_cnt_rsp),
        .cnt_oob       (ls_cnt_oob),
        .cnt_order_err (ls_cnt_order_err),
        .cnt_drain_err (ls_cnt_drain_err),
        .max_noresp    (ls_max_noresp),
        .max_grant_wait(ls_max_grant_wait),
        .cnt_bank_hit  (ls_cnt_bank_hit),
        .cnt_bank_miss (ls_cnt_bank_miss),
        .cnt_bypass    (ls_cnt_bypass),
        .cnt_fill_row  (ls_cnt_fill_row),
        .cnt_underrun  (ls_cnt_underrun),
        .cnt_hint_drop (ls_cnt_hint_drop),
        .cnt_fill_dup  (ls_cnt_fill_dup),
        .wm_hit_anom   (ls_wm_hit_anom),
        .wm_infill     (ls_wm_infill),
        .wm_queued     (ls_wm_queued),
        .wm_evicted    (ls_wm_evicted),
        .wm_uncovered  (ls_wm_uncovered),
        .sm_hit_anom   (ls_sm_hit_anom),
        .sm_cov_insuf  (ls_sm_cov_insuf),
        .sm_infill     (ls_sm_infill),
        .sm_queued     (ls_sm_queued),
        .sm_evicted    (ls_sm_evicted),
        .sm_uncovered  (ls_sm_uncovered),
        .cnt_wall_mfill(ls_cnt_wall_mfill),
        .resid         (ls_resid)
    );

    // ====================================================================
    // [P2b] hint 行游走器: 领先扫描 LEAD 行, 每显示行 3 拍 hint
    //   (缩放行 → 墙左 → 墙右; 单拍单行, 配合 line_supply 单写口入队)。
    //   [v2.4 板测修复] 首两版 bit(8AAD9F8C/F002DF6C)动画帧整屏花屏根因 =
    //   供数结构性过载 + hint 记账三缺陷(p3wall 实测: 每帧 occmin=0,
    //   mm≈300k/307k, fill 634~780 行 < hint 需求 ~960 行 ⇒ 队列恒满, hint
    //   无序丢弃 → 消费者逐 miss(250/帧, 其中 ~75/帧 4096 拍超时旁路) →
    //   FIFO 全帧干涸):
    //   修① 墙行 kind=0 偶步(320 字): 墙路径只读偶列即覆盖充分。仿真实测 fb
    //       端口持续吞吐 ≈0.48 字/拍(v2.3/v2.4 两版 fill 恒 ~633 行/帧饱和,
    //       每帧 ≈1316 拍/行), 全墙全宽(≈985k 拍/帧)乃至动画槽全宽(≈1.1M 拍/
    //       帧)均超帧预算 833k ⇒ 队列恒满, hint 无序丢弃 → 消费者 miss 停顿
    //       链(250/帧, 75/帧 4096 拍超时) → FIFO 全帧干涸(occmin=0)。v2.5 墙
    //       行全偶步后 k1 帧 demand ≈347k 字 ≈ 86% 预算, 缩放路径撞偶步行经
    //       miss 优先队列补填自愈。
    //   修② nsy_acc 锚定: 累加器在 rect 首行(hw_hint==nsc_gy)与尾预发行
    //       (hw_hint==HW_TAIL, 即下一帧行 0)强制归零 2^11 —— 修复两缺陷:
    //       a) 原按绝对显示行累加, 而 scaler 用 rect 相对行, gy>0 的轨迹
    //          (slot2/3 进入、全部退出行)源行号整体偏移 gy·S/2^12;
    //       b) 原帧尾 acc 从本帧 rect 结束值继续, 下一帧行 0..7 预发的源行
    //          号偏移 ~(480-h)·S/2^12 行, 预发全废。
    //   修③ resync 不再跳行: vsync 后 hw_hint←0(acc←2^11), 行 0.. 走正常
    //       LEAD hint(已覆盖行被 line_supply 入队去重); 原.hw_hint←8 使
    //       预发失误的行 0..7 永无 hint, 帧头链式 miss。
    //   修④ 尾预发窗 480..487 → 480..481(行 0..1): 原 8 行 16 fill > WAYS=4,
    //       预发把行 0 需要的 (slot,0) 自己挤出。2 行 3 fill ≤ 4 路驻留。
    //   缩放行步长跨帧近似(S(k) vs S(k+1))维持已声明口径(±1 行舍入, ≤2 行
    //   连续, 消费者 miss 由全宽补填自愈, 单行停顿 ~684 拍 ≪ FIFO 余量)。
    //   pending 首 frame 的缩放行步长用 k=1 首帧常量(生成表值, 本地登记)。
    // ====================================================================
    localparam [9:0]  HW_LEAD = 10'd2;
    localparam [9:0]  HW_TAIL = 10'd480;
    localparam [9:0]  HW_END  = 10'd482;           // [v2.4 修④] 预发行 0..1
    // [E1 修复] HW_S_ENTRY_K1 8091→8192: 常量抄错(8091 是 k=2 的 S, 非 k=1)。
    //   nn_scaler_table 实测 k=1 S=8192(ASTATE 一致)。pending 期 hint 步长须与
    //   消费者 k=1 帧实际 S 一致, 否则预取源行号偏离消费需求(需求生成/消费不同帧参数)。
    localparam [13:0] HW_S_ENTRY_K1 = 14'd8192;   // 表 k=1(进入) S=8192 — nn_scaler_table
    localparam [13:0] HW_S_EXIT_K1  = 14'd4096;   // 表 k=29(退出 k=1 → k_geo=29) ✓
    reg  [9:0]  hw_scan, hw_hint, hw_py_d;
    reg  [25:0] hw_nsy_acc;
    reg  [1:0]  hw_phase;                          // 0 空闲 1 缩放 2 墙左 3 墙右
    reg         hw_pend;                           // 触发后首个动画 vsync 未到
    reg         vs_d1_q;
    wire        hw_vs_d1    = vs_d1_q;
    // [v2.7] 行首判定排除 y==0: vsync 后首个位置 (y=0) 不计转行(原 479→0
    //   误计一次 ⇒ scan 帧首即 1, 全帧前移一行)
    wire        hw_row_start = fe_pos_valid && (fe_pos_y != hw_py_d) &&
                               (fe_pos_y != 10'd0);
    wire        hw_tail     = (hw_hint >= HW_TAIL);
    wire [9:0]  hw_r        = hw_tail ? (hw_hint - HW_TAIL) : hw_hint;
    wire        hw_anim_v   = (hw_r >= nsc_gy) && (hw_r < nsc_gy + nsc_h);
    // [缺陷1 修复] 墙半区判断: 图墙 2×2 格, 上下半区边界 = 240(每格 240 行),
    //   原 hw_half = hw_r[9](即 hw_r≥256) ⇒ 半区边界错位 16 行(240..255 段
    //   hw_half 已为 1 而 hw_wall_ly 仍按上半区减 240, 二者不一致, 墙 hint 的
    //   slot 半区与行号错配 ⇒ 墙行预取错行 → 墙行 miss → 背景花屏)。
    //   统一以 240 为半区边界: hw_half=(hw_r≥240), 与 hw_wall_ly 减 240 一致。
    wire        hw_half     = (hw_r >= 10'd240);
    wire [9:0]  hw_wall_ly  = hw_half ? (hw_r - 10'd240) : hw_r;
    wire [9:0]  hw_wall_y   = {hw_wall_ly[8:1], 2'b00};
    // 尾发/在发用的缩放行步长: pending=首帧常量; 动画帧=当前帧几何(近似, r≤8 精确)
    wire [13:0] hw_walk_S   = anim_vf ? nsc_S :
                          (anim_exit ? HW_S_EXIT_K1 : HW_S_ENTRY_K1);
    // [v2.4 修②] 行 0 锚定: rect 首行与尾预发行 0 处累加器归 2^11(零乘法)
    wire        hw_anchor   = (hw_hint == nsc_gy) || (hw_hint == HW_TAIL);
    wire [25:0] hw_acc_eff  = hw_anchor ? 26'd2048 : hw_nsy_acc;
    // [A3 有界预取] hint valid/ready 握手: ls_hint_rdy=0(q 将满反压)时不进入发射
    //   序列(hw_phase 停 0, hw_hint 不推进), q 腾出空间再继续 —— 预取距离由
    //   LEAD=2(消费位置 hw_scan + LEAD)与队列反压双重限定, 需求不丢失(cnt_hint_drop=0)。
    //   另 hw_can 原本就限 hw_hint < hw_scan+LEAD(消费位置限定预取距离), 保持不变。
    wire        hw_can = anim_busy && (hw_phase == 2'd0) && ls_hint_rdy &&
                         ( hw_pend ? (hw_hint >= HW_TAIL && hw_hint < HW_END) :
                          anim_vf  ? ((hw_hint < hw_scan + HW_LEAD && hw_hint < HW_TAIL) ||
                                      (hw_hint >= HW_TAIL && hw_hint < HW_END)) : 1'b0);

    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            hw_scan <= 10'd0; hw_hint <= 10'd0; hw_py_d <= 10'd0;
            hw_nsy_acc <= 26'd2048; hw_phase <= 2'd0; hw_pend <= 1'b0;
            vs_d1_q <= 1'b0;
            ls_hint_v <= 1'b0;
            ls_hint_s <= 2'd0;
            ls_hint_y <= 10'd0;
            ls_hint_k <= 1'b0;
        end else begin
            vs_d1_q <= vs_start_pulse;
            hw_py_d <= fe_pos_y;
            if (vs_start_pulse) hw_scan <= 10'd0;
            if (hw_row_start)   hw_scan <= hw_scan + 10'd1;
            // vsync 后 1 拍重同步(动画帧起: 从行 0 走正常 LEAD hint, 已预发
            //   行由 line_supply 覆盖去重跳过) [v2.4 修③]
            if (hw_vs_d1 && anim_busy) begin
                hw_hint    <= 10'd0;
                hw_nsy_acc <= 26'd2048;
                hw_phase   <= 2'd0;
                hw_pend    <= 1'b0;
            end else if (anim_busy && !anim_vf && !hw_pend && hw_phase == 2'd0) begin
                // 触发(pending)进入: 帧尾预发模式起
                hw_hint    <= HW_TAIL;
                hw_nsy_acc <= 26'd2048;
                hw_pend    <= 1'b1;
            end else begin
                case (hw_phase)
                    2'd0: if (hw_can) begin
                        // 拍 1: 缩放行(pending 期无条件发 —— 此时 nsc 几何是
                        //   上一动画残留, 不能作门控; 多发的行由覆盖位去重/
                        //   miss 补填兜住, 仅空耗填充带宽于消隐窗)
                        ls_hint_v  <= hw_anim_v || hw_pend;
                        ls_hint_s  <= anim_slot;
                        ls_hint_y  <= hw_acc_eff[21:12];
                        ls_hint_k  <= 1'b1;
                        hw_phase   <= 2'd1;
                    end
                    2'd1: begin
                        // [缺陷2 修复] valid/ready 接受一致性: phase 1/2 也仅在
                        //   ls_hint_rdy=1 时发射并推进, 否则保持当前 phase、ls_hint_v=0
                        //   等待(反压)。原 phase 1/2 无条件发射, hint_rdy 已翻 0 时
                        //   hint_v 仍发出被 line_supply 拒收 ⇒ cnt_hint_drop 爆表。
                        //   现每拍发射前查 hint_rdy, 握手一致 ⇒ hint_drop 应≈0。
                        if (ls_hint_rdy) begin
                            // 拍 2: 墙左 [v2.5] kind=0 偶步(320 字)
                            ls_hint_v  <= ~hw_r[0];
                            ls_hint_s  <= {hw_half, 1'b0};
                            ls_hint_y  <= hw_wall_y;
                            ls_hint_k  <= 1'b0;
                            hw_phase   <= 2'd2;
                        end else begin
                            ls_hint_v  <= 1'b0;      // 反压等待, 不发
                        end
                    end
                    2'd2: begin
                        // [缺陷2 修复] 同 phase 1: hint_rdy 门控, 反压保持
                        if (ls_hint_rdy) begin
                            // 拍 3: 墙右 → 行完成 (kind=0 同拍 2)
                            ls_hint_v  <= ~hw_r[0];
                            ls_hint_s  <= {hw_half, 1'b1};
                            ls_hint_y  <= hw_wall_y;
                            ls_hint_k  <= 1'b0;
                            hw_phase   <= 2'd0;
                            hw_hint    <= hw_hint + 10'd1;
                            // 行号累加与拍 1 的发射条件同口径 [v2.4 修②]
                            if (hw_anim_v || hw_pend)
                                hw_nsy_acc <= hw_acc_eff + {12'd0, hw_walk_S};
                        end else begin
                            ls_hint_v  <= 1'b0;      // 反压等待, 不发不推进
                        end
                    end
                    default: begin
                        ls_hint_v  <= 1'b0;
                        hw_phase   <= 2'd0;
                    end
                endcase
            end
        end
    end

    display_fetch_engine #(
        .FRAME_WIDTH  (640),
        .FRAME_HEIGHT (480)
    ) u_fetch (
        .clk               (ctrl_clk),
        .rst_n             (core_rst_n),
        .arm               (loader_init_done),
        .frame_start_pulse (vs_start_pulse),
        .pos_x             (fe_pos_x),
        .pos_y             (fe_pos_y),
        .pos_valid         (fe_pos_valid),
        .pos_take          (fe_pos_take),
        .rsp_valid         (sq_v),
        .rsp_data          (sq_data),
        .rsp_en            (sq_en),
        .rsp_tag           (sq_tag),
        .fifo_wr_en        (fe_wr_en),
        .fifo_wr_data      (fe_wr_data),
        .fifo_almost_full  (fe_almost_full),
        .fetching          (fe_fetching),
        .fetch_frame_accept(fetch_frame_accept)   // [A1] 引出帧接受脉冲
    );

    boot_frame_observer u_boot_frame_observer (
        .ctrl_clk(ctrl_clk), .ctrl_rst_n(core_rst_n),
        .request_toggle(boot_frame_request_r), .complete_toggle(boot_frame_complete_w),
        .pixel_clk(pixel_clk), .pixel_rst(rst_pixel),
        .axis_valid(axis_s_valid), .axis_ready(axis_s_ready), .axis_sof(axis_s_user)
    );

    // 异步 FIFO: 写侧 AFULL_MARGIN=36(019 上板值)
    async_pixel_fifo #(
        .DEPTH        (1024),
        .AFULL_MARGIN (36)
    ) u_pixel_fifo (
        .wr_clk      (ctrl_clk),
        .wr_rst_n    (core_rst_n),
        .wr_en       (fe_wr_en),
        .wr_data     (fe_wr_data),
        .full        (),
        .almost_full (fe_almost_full),
        .rd_clk      (pixel_clk),
        .rd_rst_n    (~rst_pixel),
        .rd_en       (src_rd_en),
        .rd_data     (src_rd_data),
        .empty       (src_empty)
    );

    // VS 下降沿脉冲 CDC: pixel 域产生单拍脉冲 -> ctrl 域 2FF -> 上升沿
    reg vs_1d;
    always @(posedge pixel_clk or posedge rst_pixel) begin
        if (rst_pixel) vs_1d <= 1'b0;
        else           vs_1d <= v_vs;
    end
    assign vs_fall_pulse = vs_1d & ~v_vs;   // 单拍, 宽 1 个 pixel_clk

    reg [1:0] vs_sync;
    reg       vs_sync_1d;
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            vs_sync    <= 2'b00;
            vs_sync_1d <= 1'b0;
        end else begin
            vs_sync    <= {vs_sync[0], vs_fall_pulse};
            vs_sync_1d <= vs_sync[1];
        end
    end
    assign vs_start_pulse = vs_sync[1] & ~vs_sync_1d;

    // pixel 域: 视频时序 + FIFO 读侧/AXIS 源
    video_timing_data u_video_timing_data (
        .I_clk (pixel_clk),
        .I_rst (rst_pixel),
        .O_hs  (v_hs),
        .O_vs  (v_vs),
        .O_de  (v_de)
    );

    // [026 第三步] 像素源 RGB888 输出改接内部线, axis_s_data 由字幕 mux 驱动
    wire [23:0] px_axis_data;

    fifo_pixel_source #(
        .HACTIVE (640),
        .VACTIVE (480)
    ) u_pixel_source (
        .I_clk         (pixel_clk),
        .I_rst         (rst_pixel),
        .I_vs          (v_vs),
        .I_de          (v_de),
        .fifo_rd_en    (src_rd_en),
        .fifo_rd_data  (src_rd_data),
        .fifo_empty    (src_empty),
        .axis_s_ready  (axis_s_ready),
        .axis_s_user   (axis_s_user),
        .axis_s_valid  (axis_s_valid),
        .axis_s_last   (axis_s_last),
        .axis_s_data   (px_axis_data)
    );

    // --------------------------------------------------------------------
    // [026 第三步] 分辨率字幕叠加(res_caption, pixel 域自研)
    //   坐标自计数(line_cnt/x_cnt 与 video_timing_data/fifo_pixel_source
    //   同拍); I_advance = de && ready => 背压时字幕与像素数据一起保持。
    //   叠加仅改数据: valid/user/last/ready 直连不变。黑底条(8,8)起
    //   16 行×80 列, 白字 8x8 "宽x高"(源尺寸, 前导零抑制)。
    // --------------------------------------------------------------------
    dashboard_time u_dashboard_time (
        .clk(pixel_clk),.rst(rst_pixel),.samples_consumed(wav_samples_consumed),
        .audio_active(wav_active),.file_bytes(dashboard_file_bytes),.file_present(dashboard_file_present),
        .file_update(dashboard_file_update),
        .time_set(1'b0),.time_set_bcd(24'd0),
        .played_bcd(dashboard_played),.played_valid(dashboard_played_valid),
        .total_bcd(dashboard_total),.total_valid(dashboard_total_valid),
        .up_bcd(dashboard_up),.second_tick()
    );
    dashboard_format u_dashboard_format (
        .clk(pixel_clk),.rst(rst_pixel),.snapshot_toggle(dashboard_request_r),
        .snapshot_data(dashboard_snapshot_r),.snapshot_acknowledge(dashboard_ack),
        .brightness(pa_bri_gear),.contrast(pa_con_gear),
        .played_bcd(dashboard_played),.played_valid(dashboard_played_valid),.up_bcd(dashboard_up),
        .total_bcd(dashboard_total),.total_valid(dashboard_total_valid),
        .file_bytes(dashboard_file_bytes),.file_present(dashboard_file_present),.file_update(dashboard_file_update),
        .text_acknowledge(dashboard_text_ack),.text_ready_toggle(dashboard_ready),
        .text_ready_bank(dashboard_ready_bank),.text_help_adjust(dashboard_help_adjust),.write_enable(dashboard_write_enable),
        .write_address(dashboard_write_address),.write_character(dashboard_write_character)
    );
    always @(posedge pixel_clk or posedge lyric_rst)begin
        if(lyric_rst)lyric_vs_d<=1'b1;else lyric_vs_d<=v_vs;
    end
    lyric_terminal u_lyrics(.ctrl_clk(ctrl_clk),.ctrl_rst(!core_rst_n),.pixel_clk(pixel_clk),.pixel_rst(lyric_rst),
        .mounted(geo_spc!=0 && sel && fsm_state!=S_FAIL && !slot_reload_busy),.mount_start(mount_start_r),.wav_slot(wav_slot_r),
        .entry_valid(lrc_entry_valid_w),.entry_slot(lrc_entry_slot_w),.entry_cluster(lrc_entry_cluster_w),.entry_size(lrc_entry_size_w),
        .fat_lba(lrc_fat_lba_w),.data_lba(geo_data_lba),.max_cluster(lrc_max_cluster_w),.spc(geo_spc),
        .sector_req(lrc_sector_req),.sector_lba(lrc_sector_lba),.sector_valid(lrc_sector_valid),.sector_byte(lrc_sector_byte),
        .sector_index(lrc_sector_index),.sector_done(lrc_sector_done),.sector_error(lrc_sector_error),
        .frame_tick(lyric_vs_d && !v_vs),.audio_active(wav_active),.samples(wav_samples_consumed),
        .read_column(lyric_read_column),.character(lyric_character),.line_valid(lyric_valid),.line_length(lyric_length),.scroll_offset(lyric_scroll));
    txt_overlay u_dashboard_text (
        .clk(pixel_clk),.rst(rst_pixel),.vs(v_vs),.hs(v_hs),.de(v_de),.advance(v_de&&axis_s_ready),
        .write_enable(dashboard_write_enable),.write_address(dashboard_write_address),
        .lyric_valid(lyric_valid),.lyric_length(lyric_length),.lyric_scroll(lyric_scroll),
        .lyric_character(lyric_character),.lyric_read_column(lyric_read_column),
        .write_character(dashboard_write_character),.ready_toggle(dashboard_ready),.ready_bank(dashboard_ready_bank),.ready_help_adjust(dashboard_help_adjust),
        .acknowledge_toggle(dashboard_text_ack),.mask(dashboard_mask),.text(dashboard_text)
    );
    // 黑色5/16不透明度=31.25%，底图11/16；文字不混合，握手与像素拍不变。
    function [7:0] dashboard_background;
        input [7:0] channel;
        reg [11:0] weighted;
        begin
            weighted = ({4'd0,channel} << 3) + ({4'd0,channel} << 1) + {4'd0,channel};
            dashboard_background = weighted[11:4];
        end
    endfunction
    wire [23:0] dashboard_background_rgb = {
        dashboard_background(adj_axis_data[23:16]),
        dashboard_background(adj_axis_data[15:8]),
        dashboard_background(adj_axis_data[7:0])};
    assign axis_s_data = dashboard_mask ? (dashboard_text ? 24'hFFFFFF : dashboard_background_rgb) : adj_axis_data;

    // --------------------------------------------------------------------
    // [task_040] 实时参数调节三件套(pixel 域, PARAM_SPEC §2):
    //   param_ctrl  拨码 2FF 同步 + 20ms 去抖 + 基线捕获 + vsync 边界换装;
    //               复位后 40ms 基线窗内拨码不生效(上电保持默认档, 拨动才变更);
    //   pixel_adjust 亮度->对比度 两级调节(纯组合, sat8 双向钳位, 无乘法器);
    //   param_osd   换装拍点亮 "BRI+nn CON d.d" 参数条 120 帧(≈2s), 重装优先;
    //   几何: 参数条 (8,28)起 120x16(VSTART 相对), 与字幕条 (8,8) 80x16 错开。
    // --------------------------------------------------------------------
    // ctrl域档位快照保持到pixel捕获ack；不将异步多位参数逐位解释为事件。
    key_adjust_ctrl u_key_adjust (
        .clk(ctrl_clk), .rst_n(core_rst_n), .switches(sw[1:0]),
        .key2_stable(key_next_stable_w), .key3_stable(wav_btn_stable_w),
        .key4_short(key4_short_r),
        .blocked(boot_metrics_mode || rescan_chord_held || rescan_chord_seen_r ||
                 rescan_pending_r || rescan_active_r),
        .ack_toggle(key_param_ack), .adjust_mode(adjust_mode), .auto_enable(auto_en),
        .request_toggle(key_param_request), .gear_snapshot(key_param_snapshot), .contrast_option(adjust_option)
    );
    param_key_commit u_param_ctrl (
        .I_clk(pixel_clk), .I_rst(rst_pixel), .I_vs(v_vs),
        .request_toggle(key_param_request), .gear_snapshot(key_param_snapshot),
        .ack_toggle(key_param_ack), .O_bri_off(pa_bri_off), .O_con_sel(pa_con_sel),
        .O_bri_gear(pa_bri_gear), .O_con_gear(pa_con_gear), .O_param_upd(pa_upd)
    );

    pixel_adjust u_pixel_adjust (
        .I_bri_off (pa_bri_off),
        .I_con_sel (pa_con_sel),
        .I_pixel   (px_axis_data),
        .O_pixel   (adj_axis_data)
    );

    // 参数常显已并入仪表盘第二行，旧两秒参数条不再叠加。


    // ====================================================================
    // [task_032] 音频集成: 测试音 / WAV 背景音乐 双音源
    //
    // 数据流(INTERFACE_SPEC §1):
    //   scanner WAV 槽 ──簇→LBA 换算──> wav_pcm_streamer(WR 域=ctrl 域)
    //        │  wr 侧经 sd_arbiter(优先级 显示加载>WAV>扫描器)取扇区
    //        v
    //   16bit mono + valid ──pcm16_to_pcm24──> 24bit stereo
    //        v  (RD 域 = pixel 域, sample_tick 驱动)
    //   audio_src_mux ← audio_tone_gen(24bit stereo 测试音, 波形逻辑未改)
    //        v
    //   audio_i2s_bridge(帧FIFO 像素→mclk / i2s_master / 官方 I2S_receiver
    //                    / 官方 audio_arc_calculate) ──> HDMI IP
    //
    // 音源选择: 无 WAV 播放 = 测试音(基础要求③验收形态); WAV 播放中 = WAV 流。
    // 关键纪律:
    //   * sample_tick 取自 audio_tone_gen 的 O_tone_tick, 其速率由分数分频
    //     25/13104 精确等于 audio_mclk/256(= i2s_master 的 LRCK), 故 bridge
    //     两侧速率严格相等、帧 FIFO 水位不漂移 —— 不得改用独立晶振分频,
    //     也不得改回像素域整数分频(会与投递速率失配而周期性欠载插静音);
    //   * play_enable 为 ctrl 域电平, wav_pcm_streamer 写侧亦在 ctrl 域,
    //     读侧 sample_tick 在 pixel 域 —— 内部已由流器自做同步, 顶层仅需
    //     保证电平稳定;
    //   * wav_active 须保持到 sample_counter 达 total_sectors×256, 否则
    //     stream_end 后残余样本排不空即被切源 → 截断/爆音(变异 m4 靶点。
    //     流器 read 侧在 ended_sync2 且 buffer 空时才停推 valid, 保证排空)。
    // ====================================================================

    // ---- 挂载完成时缓存几何参数(data_lba / spc), 供簇→LBA 换算 ----
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            geo_data_lba <= 32'd0;
            geo_spc      <= 8'd0;
        end else if (mount_done && !mount_error) begin
            geo_data_lba <= fat_data_start_w;
            geo_spc      <= fat_spc_w;
        end
    end

    // ---- 簇→LBA 换算(纯组合; 目标槽由**运行时** wav_slot_r 选择) ----
    //   start_lba     = data_lba + (first_cluster - 2) × sectors_per_cluster
    //   total_sectors = (size + 511) >> 9
    //   可用性判定 = 槽有效 ∧ 首簇号 ≥ 2 ∧ 尺寸非零:
    //     簇号 < 2  → 目录项未分配(无有效 WAV);
    //     尺寸 == 0 → 空文件(VERIFICATION_CONTRACT §3 "size 为 0 时不启动");
    //   两者任一不成立则流器参数置 0 且 play_enable 被屏蔽, 输出恒为测试音。
    //   [032 续] WAV_PLAY_SLOT 语义变更: 由"编译期固定目标槽"降为"复位初始槽"
    //   (默认 0 ⇒ 上电行为与上一版逐拍一致; TB 覆写初值的能力保留)。
    //   下面三选一的形式与改动前逐字对应, 只把判据源换成 wav_slot_r。
    wire [31:0] wav_sel_first_cluster = (wav_slot_r == 2'd1) ? wav1_first_cluster_w :
                                        (wav_slot_r == 2'd2) ? wav2_first_cluster_w :
                                        (wav_slot_r == 2'd3) ? wav3_first_cluster_w :
                                                               wav0_first_cluster_w;
    wire [31:0] wav_sel_size          = (wav_slot_r == 2'd1) ? wav1_size_w :
                                        (wav_slot_r == 2'd2) ? wav2_size_w :
                                        (wav_slot_r == 2'd3) ? wav3_size_w :
                                                               wav0_size_w;
    wire        wav_sel_valid         = (wav_slot_r == 2'd1) ? wav_valid_w[1] :
                                        (wav_slot_r == 2'd2) ? wav_valid_w[2] :
                                        (wav_slot_r == 2'd3) ? wav_valid_w[3] :
                                                               wav_valid_w[0];

    // 完整保留cluster<2夹零偏移和可播保护；合法簇偏置分配在32bit模域等价。
    wire [31:0] wav_data_lba_bias = geo_data_lba - {23'd0,geo_spc,1'b0};
    wire [31:0] wav_total_sectors_w = (wav_sel_size + 32'd511) >> 9;
    wire [3:0] wav_slot_ok_calc;
    reg [3:0] wav_slot_ok_v;
    // 目录判定在扫描结束前稳定；换曲有至少16拍重装窗，挂载/重扫禁止play_req。
    // 四槽可播位提前一拍缓存，保护与32位回绕算式不变，仲裁不穿过文件大小长链。
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if(!core_rst_n) wav_slot_ok_v <= 4'd0;
        else wav_slot_ok_v <= wav_slot_ok_calc;
    end
    // 复用四槽可播位, 保留同一32位尺寸回绕判据。
    wire        wav_present = wav_slot_ok_v[wav_slot_r];
    wire [31:0] wav_start_lba_w = wav_present
                                  ? ((wav_sel_first_cluster < 32'd2) ? geo_data_lba :
                                     (wav_data_lba_bias + (wav_sel_first_cluster * {24'd0, geo_spc})))
                                  : 32'd0;

    // ---- [task_044 O-1] 流器几何参数寄存一级 ----
    //   4:1 选择 + 32 位加/乘/比较的组合链直进流器, 是 route.timing 全局最差
    //   5 条路径(cur_lba/sd_lba 的 ce 端点)的唯一来源。此处寄存一级, 流器只
    //   见寄存器输出。等价性(流器取到的 LBA 序列逐值不变):
    //   流器只在两处采这两个输入 —— ① WS_IDLE 起播锁存(需 play_enable=1);
    //   ② WS_FILL 每扇区完成时与 total_sectors 比较(播放进行中)。
    //   两输入仅在 wav_slot_r 切换(经 slot_adv_w)时变化, 而每次切换都伴随
    //   ≥16 拍重载窗(slot_reload_busy 把 play_req 压低, 流器被压回 WS_IDLE
    //   不锁存); 窗退时新值进入寄存器已 ≥16 拍, 锁存值与组合值相同。
    //   播放进行中两输入恒定, 逐拍寄存输出恒等于组合值; 复位值 0 与组合
    //   复位态(空槽 ⇒ 0)一致。tb_o1lba 的 A/B 值序列 diff 为本论证的仿真侧。
    reg  [31:0] wav_start_lba_r;
    reg  [31:0] wav_total_sectors_r;
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            wav_start_lba_r     <= 32'd0;
            wav_total_sectors_r <= 32'd0;
        end else begin
            wav_start_lba_r     <= wav_start_lba_w;
            wav_total_sectors_r <= wav_total_sectors_w;
        end
    end

    // ---- 换歌目标搜索: 只在**有效**槽之间循环 ----
    //   卡上常只放 1~3 首、且不保证从 WAV1 起连续。朴素 (slot+1) mod 4 会落到
    //   缺失/空文件槽上 ⇒ wav_present 归 0 ⇒ 播放静默中断, 且板上无任何错误码。
    //   无其他有效槽时返回 cur, 由 song_chg_w 的"变了才动"判定 ⇒ 单歌卡纯 no-op。
    //
    //   每槽可播位四路并行, 各路直接取本槽字段(无 4:1 选择), 判据与
    //   wav_present 同义: 槽有效 ∧ 首簇号 ≥ 2 ∧ 扇区数 (size+511)>>9 非零。
    //   扇区数按 32 位回绕计算(与 wav_total_sectors_w 同), size ≥ 0xFFFF_FE01
    //   时回绕为 0 而不可播, 故尺寸项取 size ∈ [1, 0xFFFF_FE00], 不能只写 size != 0。
    //   [task_044 O-3] 尺寸项化简: "0 < sz ≤ 0xFFFF_FE00" 的 32 位常量比较对
    //   (进位链实现, route 面积 +58 主源)换成纯 LUT 等价式 —— 位域判据:
    //   sz≠0 ⇔ |sz; sz>0xFFFF_FE00 ⇔ sz[31:9] 全 1 ∧ sz[8:0] 非 0(回绕边界
    //   之下无例外, 全输入域 2^32 点穷举失配 0, 见 tb/tb_o3_exh.v +
    //   sim/p1_equiv/o3_numpy_exh.py 双路径证明), 故两式逐点同值:
    function sz_playable;
        input [31:0] sz;
        begin
            sz_playable = |sz & ~(&sz[31:9] & |sz[8:0]);
        end
    endfunction
    assign wav_slot_ok_calc[0] = wav_valid_w[0] && (wav0_first_cluster_w >= 32'd2)
                              && sz_playable(wav0_size_w);
    assign wav_slot_ok_calc[1] = wav_valid_w[1] && (wav1_first_cluster_w >= 32'd2)
                              && sz_playable(wav1_size_w);
    assign wav_slot_ok_calc[2] = wav_valid_w[2] && (wav2_first_cluster_w >= 32'd2)
                              && sz_playable(wav2_size_w);
    assign wav_slot_ok_calc[3] = wav_valid_w[3] && (wav3_first_cluster_w >= 32'd2)
                              && sz_playable(wav3_size_w);

    //   候选按 cur+1 → cur+2 → cur+3 (mod 4) 的优先级取首个可播槽:
    //   {v,v} 的第 i 位 = v[i mod 4], 右移 (cur+1) 后第 0/1/2 位依次对应三个候选。
    wire [7:0] wav_ok_rot    = {wav_slot_ok_v, wav_slot_ok_v} >> (wav_slot_r + 2'd1);
    wire [1:0] wav_next_slot = wav_ok_rot[0] ? (wav_slot_r + 2'd1) :
                               wav_ok_rot[1] ? (wav_slot_r + 2'd2) :
                               wav_ok_rot[2] ? (wav_slot_r + 2'd3) :
                                               wav_slot_r;
    wire       song_chg_w    = wav_next_press_r && (wav_next_slot != wav_slot_r);

    // ---- 曲目完成事件: pixel 域翻转 → ctrl 域 2FF 同步 + 任意沿 = 单拍脉冲 ----
    //   SDC 已声明 ctrl↔pixel 双向 false path(TD 不支持 set_clock_groups), 本路径
    //   不进 STA —— 正确性靠翻转 + 2FF + 边沿检测的结构保证: 源端一次事件只翻一次,
    //   两次事件相隔 ≥ 一整首曲目, 远大于同步延迟, 不会漏沿或并沿。
    reg wav_done_s1, wav_done_s2, wav_done_s3;
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            wav_done_s1 <= 1'b0;
            wav_done_s2 <= 1'b0;
            wav_done_s3 <= 1'b0;
        end else begin
            wav_done_s1 <= wav_track_done_tgl;
            wav_done_s2 <= wav_done_s1;
            wav_done_s3 <= wav_done_s2;
        end
    end
    wire wav_track_done = wav_done_s2 ^ wav_done_s3;

    // ---- 播完自动推进 ----
    //   只在用户仍开着播放时推进(短按停止后不得自己续播)。推进目标与长按换歌共用
    //   wav_next_slot(跳过不可播槽、回绕); 单曲卡 wav_next_slot == wav_slot_r, 此时
    //   也必须走一次重载窗, 否则流器停在 WS_END 不再出样(只剩默认测试音) ——
    //   故自动分支不带"目标不同"条件。wav_present 一票否决: 当前槽已不可播的
    //   异常下不推进, 停在默认音(与播完即停的旧行为一致, 不会反复重载)。
    wire wav_auto_adv = wav_track_done && wav_play_en_c;
    wire slot_adv_w   = song_chg_w || (wav_auto_adv && wav_present);

    // ---- 切槽重载窗 ----
    //   换歌要让流器**真的**从头重装载。start_lba 是组合输入, 但流器内部
    //   cur_lba / sectors_read / wr_ptr / rd_ptr 仍锁在旧槽, 它唯一的重装载
    //   机制是自己的 "!play_enable ⇒ 回 WS_IDLE 清指针" 分支 ⇒ 必须给
    //   play_enable 一个低窗。
    //   ⚠ 窗口**不能只按"两个域各看到一拍"来定**(那样 16 拍就够): 退窗时旧槽
    //   可能还有一笔 s1 事务在途(或被锁在仲裁器的 s1_pend 里)。若退窗时它没
    //   结束, 流器由 WS_IDLE 进 WS_REQ 而 grant 依旧 = G_S1 ⇒ s1_busy 恒真
    //   (s1_busy 含 s1_req 自身)⇒ 流器**永远退不出 WS_REQ**, 音频永久卡死且
    //   无错误码。故: 驻满最短窗后还要等 arb_wav_busy 落 0(在途事务 + pend
    //   全部排干)才退窗; 另设上限, 防总线异常时退化成永久静音。
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            wav_reload_t   <= 17'd0;
            wav_reload_min <= 5'd0;
        end else if (slot_adv_w) begin
            wav_reload_t   <= WAV_RELOAD_MAX_CYC;
            wav_reload_min <= WAV_RELOAD_MIN_CYC;
        end else if (wav_reload_t != 17'd0) begin
            if (wav_reload_min != 5'd0)
                wav_reload_min <= wav_reload_min - 5'd1;
            else if (!arb_wav_busy || wav_reload_t == 17'd1)
                wav_reload_t <= 17'd0;
            else
                wav_reload_t <= wav_reload_t - 17'd1;
        end
    end
    assign slot_reload_busy = (wav_reload_t != 17'd0);

    // ---- 播放请求电平(ctrl 域) ----
    //   play_req = 用户已开播放 ∧ 当前槽可用 ∧ 不在切槽重载窗内。该电平既作
    //   流器写侧使能, 也作 sd_arbiter 源1 的请求门控(避免未播放时流器每扇区
    //   握手的 1 拍 sd_req 误抢显示加载的优先级)。
    wire play_req = wav_play_en_c && wav_present && !slot_reload_busy &&
                     !rescan_pending_r && !rescan_start;

    // ---- WAV 键: 短按 = 播放/停止(判据不变), 长按 = 换歌 (与 027 C1 同构) ----
    //   按住: 计数达 SONG_PRESS_CYCLES 且未触发过 -> wav_next_press_r 单拍
    //         + wav_lp_marked 锁存(按住不重复换歌);
    //   松开沿: marked=0(本次没长按) 且当前槽可用 -> 翻转播放使能。
    //   marked 的作用正是让长按后的那次松开**不要**再触发短按, 否则换歌会顺带
    //   把开关翻过去, 且 play_enable 落 0 会让流器从头重播。
    //   槽更新写在 if/else **之外**: 长按脉冲与松开同拍时走的是松开分支,
    //   若把赋值写在"按住"分支里, 这一整次换歌会被静默吞掉。
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            wav_btn_d        <= 1'b1;
            wav_play_en_c    <= 1'b0;
            wav_slot_r       <= WAV_PLAY_SLOT;
            wav_lp_cnt       <= 32'd0;
            wav_lp_marked    <= 1'b0;
            wav_next_press_r <= 1'b0;
        end else if (rescan_request || rescan_pending_r || rescan_active_r ||
                     rescan_start || boot_metrics_mode) begin
            wav_btn_d        <= wav_btn_stable_w;
            wav_play_en_c    <= 1'b0;
            wav_lp_cnt       <= 32'd0;
            wav_lp_marked    <= !wav_btn_stable_w;
            wav_next_press_r <= 1'b0;
            if (rescan_start)
                wav_slot_r <= WAV_PLAY_SLOT;
        end else if (adjust_mode) begin
            wav_btn_d <= wav_btn_stable_w;
            wav_lp_cnt <= 32'd0;
            wav_lp_marked <= !wav_btn_stable_w;
            wav_next_press_r <= 1'b0;
        end else begin
            wav_next_press_r <= 1'b0;           // 单拍脉冲默认清零
            wav_btn_d        <= wav_btn_stable_w;
            if (!wav_btn_stable_w) begin        // 按住(消抖确认后)
                if (wav_lp_cnt < SONG_PRESS_CYCLES - 1) begin
                    wav_lp_cnt <= wav_lp_cnt + 32'd1;
                end else if (!wav_lp_marked) begin
                    wav_lp_marked    <= 1'b1;
                    wav_next_press_r <= 1'b1;
                end
            end else begin                      // 松开
                wav_lp_cnt    <= 32'd0;
                wav_lp_marked <= 1'b0;
                if (!wav_btn_d && !wav_lp_marked && wav_present)
                    wav_play_en_c <= ~wav_play_en_c;   // 短按: 改动前的同一判据
            end
            if (slot_adv_w)
                wav_slot_r <= wav_next_slot;
        end
    end

    // ---- sample_tick 跨域: ctrl/pixel 同源时钟(均由板载 50M PLL 派生),
    //      但节拍由 pixel 域 tone_gen 产生, 流器读侧在 pixel 域, 故直连。
    //      play_enable 由 ctrl 域电平直送流器写侧(同域), 无需 2FF。

    // ---- sd_arbiter: 三源整扇区事务仲裁 ----
    //   源0 = 显示加载(fat32_lite 外引的 file_streamer 扇区口)
    //   源1 = WAV 流器写侧(请求门控 play_req: 未播放时不占用仲裁优先级)
    //   源2 = 选择性加载链；挂载扫描仍由 fat32_lite 内部直连。
    //   三源沿用整扇区事务契约和既有优先级。

    sd_arbiter u_sd_arb (
        .clk          (ctrl_clk),
        .rst_n        (core_rst_n),
        // 源0: 显示加载(文件流器扇区口)
        .s0_req       (fb_sector_req),
        .s0_lba       (fb_sector_lba),
        .s0_busy      (fb_sector_busy),
        .s0_done      (fb_sector_done),
        .s0_valid     (fb_sector_valid),
        .s0_byte      (fb_sector_byte),
        .s0_byte_index(fb_sector_byte_index),
        .s0_error     (fb_sector_error),
        // 源1: WAV 流(play_req 门控)
        .s1_req       (arb_wav_req && play_req),
        .s1_lba       (wav_sd_lba_w),   // 流器写侧自维护的请求 LBA
        .s1_busy      (arb_wav_busy),
        .s1_done      (arb_wav_done),
        .s1_valid     (arb_wav_valid),
        .s1_byte      (arb_wav_byte),
        .s1_byte_index(arb_wav_byte_index),
        .s1_error     (arb_wav_error),
        // 源2: 选择性加载链，使用既有空闲源
        .s2_req       (sel_sector_req),
        .s2_lba       (sel_sector_lba),
        .s2_busy      (arb_scan_busy),
        .s2_done      (arb_scan_done),
        .s2_valid     (arb_scan_valid),
        .s2_byte      (arb_scan_byte),
        .s2_byte_index(arb_scan_byte_index),
        .s2_error     (arb_scan_error),
        // 输出 → SD 读链
        .s3_req(lrc_sector_req),.s3_lba(lrc_sector_lba),
        .s3_allow(fsm_state==S_SHOW && fill_need==0 && !read_busy && !loader_load_busy && !sel_busy && (!play_req || !wav_low_sync[1])),
        .s3_done(lrc_sector_done),.s3_valid(lrc_sector_valid),.s3_byte(lrc_sector_byte),.s3_byte_index(lrc_sector_index),.s3_error(lrc_sector_error),
        .sd_req       (sd_arb_req),
        .sd_lba       (sd_arb_lba),
        .sd_busy      (sd_arb_busy),
        .sd_done      (sd_arb_done),
        .sd_valid     (sd_arb_valid),
        .sd_byte      (sd_arb_byte),
        .sd_byte_index(sd_arb_byte_index),
        .sd_error     (sd_arb_error)
    );

    // 流器输出使能: 播放请求 ∧ 槽可用(排空期 wav_stream_active 维持, 使
    //   wav_active 保持到残余样本耗尽 —— 变异 m4 靶点)
    wire wav_stream_en = play_req;

    // CTRL在已提交视图更新后的下一拍建立一致快照，ack返回前总线保持。
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            dashboard_snapshot_r <= 103'd0;
            dashboard_request_r <= 1'b0;
            dashboard_capture_pending <= 1'b0;
            dashboard_ack_sync <= 2'b00;
        end else begin
            dashboard_capture_pending <= vs_start_pulse;
            dashboard_ack_sync <= {dashboard_ack_sync[0],dashboard_ack};
            if (dashboard_capture_pending && dashboard_ack_sync[1] == dashboard_request_r) begin
                dashboard_snapshot_r <= {focus_w,focus_h,cap_w_c,cap_h_c,wav_sel_size,
                    wav_slot_r,wav_present,slot_ready_r[cur_focus],auto_en,adjust_mode,adjust_option};
                dashboard_request_r <= ~dashboard_request_r;
            end
        end
    end
    // ---- wav_pcm_streamer: WAV 字节流 → 16bit mono 采样 ----
    wav_pcm_streamer u_wav_streamer (
        // 写侧(ctrl 域)
        .wr_clk        (ctrl_clk),
        .wr_rst_n      (core_rst_n),
        .play_enable   (wav_stream_en),
        .start_lba     (wav_start_lba_r),
        .total_sectors (wav_total_sectors_r),
        .sd_req        (arb_wav_req),
        .sd_lba        (wav_sd_lba_w),   // 流器写侧自维护的请求 LBA
        .sd_busy       (arb_wav_busy),
        .sd_valid      (arb_wav_valid),
        .sd_byte       (arb_wav_byte),
        .sd_byte_index (arb_wav_byte_index),
        .sd_done       (arb_wav_done),
        .sd_error      (arb_wav_error),
        // 读侧(pixel 域)
        .rd_clk        (pixel_clk),
        .rd_rst_n      (~rst_pixel),
        .sample_tick   (tone_tick),
        .sample_out    (wav_pcm_sample),
        .sample_valid  (wav_pcm_valid),
        .sample_ready  (1'b1),
        // 状态
        .stream_active (wav_stream_active),
        .stream_end    (wav_stream_end),
        .buffer_low    (wav_buffer_low),
        .sample_counter(wav_samples_consumed),
        .track_done_tgl(wav_track_done_tgl)
    );

    // ---- 16→24bit + mono→stereo 适配 ----
    pcm16_to_pcm24 u_pcm_adapt (
        .sample_in    (wav_pcm_sample),
        .sample_valid (wav_pcm_valid),
        .left_out     (wav24_left),
        .right_out    (wav24_right),
        .valid_out    (wav24_valid)
    );

    // ---- 音源选择: WAV 播放中(stream_active)则用 WAV, 否则测试音 ----
    //   wav_active = 播放请求 ∧ 流器 stream_active —— 保证停止播放/排空后
    //   立即回落测试音; 排空期间 stream_active 仍为高(流器维持至样本耗尽)。
    assign wav_active = play_req && wav_stream_active;

    audio_src_mux u_audio_src_mux (
        .clk        (pixel_clk),
        .rst_n      (~rst_pixel),
        .wav_valid  (wav24_valid),
        .wav_ready  (),
        .wav_left   (wav24_left),
        .wav_right  (wav24_right),
        .wav_active (wav_active),
        .arp_valid  (tone_valid),
        .arp_ready  (),
        .arp_left   (tone_left),
        .arp_right  (tone_right),
        .out_valid  (audio_valid_pre),
        .out_ready  (1'b1),
        .out_left   (audio_left_pre),
        .out_right  (audio_right_pre)
    );

    // ---- 测试音源(波形逻辑未改; 仅新增 tone_tick 引出) ----
    audio_tone_gen u_audio_tone_gen (
        .I_clk              (pixel_clk),
        .I_rst              (rst_pixel),
        .O_audio_valid      (tone_valid),
        .O_audio_left_data  (tone_left),
        .O_audio_right_data (tone_right),
        .O_tone_tick        (tone_tick)
    );

    // ---- I2S 化投递 + 官方 ACR(返工核心) ----
    //   首版把音源 mux 输出直送加密 IP: 仿真在 IP 边界逐拍核对全部正确
    //   (valid 单拍/间隔恒定/CTS=25200/N=6144/L=R 非零), 但上板**完全无声**。
    //   task_018 以 8 轮上板 A/B 听感定案: 生产音频架构 = I2S 化
    //   (源 → I2S master → 官方 I2S_receiver → 官方 ACR → IP); task_021 按该
    //   形态上板出声验证。本例化即把 032 音源改接到该已验证形态, 并使
    //   audio_mclk 承担真实负载(此前无负载, 仅预留)。
    audio_i2s_bridge u_audio_bridge (
        .I_clk_pixel        (pixel_clk),
        .I_clk_mclk         (audio_mclk),
        .I_rst              (rst_pixel),
        .I_frame_valid      (audio_valid_pre),
        .I_frame_left       (audio_left_pre),
        .I_frame_right      (audio_right_pre),
        .O_audio_valid      (audio_valid),
        .O_audio_left_data  (audio_left_data),
        .O_audio_right_data (audio_right_data),
        .O_acr_valid        (acr_valid),
        .O_acr_cts          (acr_cts),
        .O_acr_n            (acr_n)
    );

    // EDID 启动读取触发: 复位释放后延时约 4ms 拉一拍 (019 蓝本)
    reg [19:0] edid_cnt;
    wire edid_trig = (edid_cnt == 20'd100000);   // 4ms @ 25.2MHz
    always @(posedge pixel_clk or posedge rst_pixel) begin
        if (rst_pixel)
            edid_cnt <= 20'd0;
        else if (edid_cnt < 20'd100000)
            edid_cnt <= edid_cnt + 20'd1;
    end

    // HDMI 1.4b 发射核心(加密 IP, 参数与 019 完全一致)
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE            ("EG"),
        .HTOTAL            (800),
        .HSA               (96),
        .HFP               (16),
        .HBP               (48),
        .HACTIVE           (640),
        .VTOTAL            (525),
        .VSA               (2),
        .VFP               (10),
        .VBP               (33),
        .VACTIVE           (480),
        .VIDEO_TPG         ("Disable"),
        .VIDEO_FORMAT      ("RGB"),
        .VIDEO_VIC         (1),
        .AUDIO_SAMPLE_RATE ("48K"),
        .IIC_SCL_DIV       (250)
    ) u_hdmi_1_4b_transmitter_core_wrapper (
        .I_pixel_clk        (pixel_clk),
        .I_rst              (rst_pixel),
        .I_edid_read_trig   (edid_trig),
        .O_edid_read_valid  (edid_read_valid),
        .O_edid_read_data   (edid_read_data),
        .I_axis_s_user      (axis_s_user),
        .I_axis_s_valid     (axis_s_valid),
        .I_axis_s_last      (axis_s_last),
        .I_axis_s_data      (axis_s_data),
        .O_axis_s_ready     (axis_s_ready),
        .I_audio_valid      (audio_valid),
        .I_audio_left_data  (audio_left_data),
        .I_audio_right_data (audio_right_data),
        .I_acr_valid        (acr_valid),
        .I_acr_cts          (acr_cts),
        .I_acr_n            (acr_n),
        .O_video_locked     (video_locked),
        .O_ddc_scl          (ddc_scl),
        .IO_ddc_sda         (HDMI_DDC_SDA),
        .O_ch0_tmds_data    (tmds_ch0_data),
        .O_ch1_tmds_data    (tmds_ch1_data),
        .O_ch2_tmds_data    (tmds_ch2_data),
        .O_clk_tmds_data    (tmds_clk_data)
    );

    assign HDMI_DDC_SCL = ddc_scl;

    hdmi_phy_wrapper #(
        .DEVICE ("EG")
    ) u_hdmi_phy_wrapper (
        .I_pixel_clk        (pixel_clk),
        .I_serial_clk       (serial_clk),
        .I_rst              (rst_pixel_phy),
        .I_tmds_channel_0   (tmds_ch0_data),
        .I_tmds_channel_1   (tmds_ch1_data),
        .I_tmds_channel_2   (tmds_ch2_data),
        .I_tmds_channel_clk (tmds_clk_data),
        .O_tmds_ch0_p       (HDMI_D0_P),
        .O_tmds_ch1_p       (HDMI_D1_P),
        .O_tmds_ch2_p       (HDMI_D2_P),
        .O_tmds_clk_p       (HDMI_CLK_P)
    );

    // --------------------------------------------------------------------
    // 观测辅助: 009 字流字数(M05 判据, 仅供 TB 层级引用, 不引出端口)
    // --------------------------------------------------------------------
    always @(posedge ctrl_clk or negedge core_rst_n) begin
        if (!core_rst_n)
            dbg_word_cnt <= 22'd0;
        else if (fat_data_valid && (dbg_word_cnt != 22'h3FFFFF))
            dbg_word_cnt <= dbg_word_cnt + 22'd1;
    end

    // [026 第三步] v_hs 改由 res_caption 消费(行计数), loader_active_buffer 改由
    // 字幕尺寸锁存消费(提交沿检测), 二者移出本表;
    // [task_032 返工] audio_mclk 移出本表: 已由 audio_i2s_bridge 作为真实时钟
    // 负载消费(i2s_master), 不再是空载预留 —— 留在此处会让工具把它同时当作
    // 时钟网与数据网。
    // [task_032] WAV 流器状态/扫描器仲裁占位端口集中接地;
    // 其余为冻结接口的未消费输出(009 查询字段/忙标志/012 状态), 集中接地。
    wire _unused = &{1'b0,
                     mount_busy,
                     query_name_w, query_size_w,
                     loader_stream_ready,
                     fe_fetching, loader_active_buffer, fb_fwrite_done,
                     edid_read_valid, edid_read_data,
                     wav_stream_end, wav_stream_active,
                     boot_meas_stage_r, boot_meas_stage_cnt_r,
                     boot_meas_total_cycles_r, boot_meas_idle_cycles_r,
                     boot_meas_init_cycles_r, boot_meas_switch_cycles_r,
                     boot_meas_mount_cycles_r, boot_meas_scan_cycles_r,
                     boot_meas_load_first_cycles_r, boot_meas_load_bg_cycles_r,
                     boot_meas_load_count_r,
                     boot_meas_first_show_valid_r, rescan_active_r,
                     rescan_complete_r, rescan_done_cnt_r,
                     rescan_pending_r,
                     1'b0};

endmodule
