# 八柱渲染器任务包

状态：待中间检验；未正式编号，尚未授权实现。首里程碑的一部分，模块通过不等于HDMI上板通过。

## Task Summary

实现由8路8位能量驱动的640×480 RGB565八柱渲染器，支持场消隐提交配色、幅度和冻结状态。

## Scope

输入/输出以 `INTERFACE_SPEC.md` 完整声明为准：视频时序、能量、消抖按键/稳定开关→像素及valid。

本任务提供可综合渲染器、独立TB、复现脚本、模块级TD证据。排除HDMI封装、PLL/PHY修改、真实音频、SDRAM、假数据板级发生器、引脚绑定。首版不做平滑和发光。

边界防御至少覆盖全零/全满、帧中复位、行过长/额外行的饱和黑色输出、按键与提交同沿、帧中能量突变不改变当前帧。

## 硬件约束（Hardware Constraints）

| 项 | 约束 |
|---|---|
| 芯片 | EG4S20BG256，HX4S20C |
| 时钟 | 外部提供25.2MHz像素时钟；不新增PLL |
| 数据 | RGB565 16位，8路8位无符号能量 |
| 存储 | 本模块不使用帧缓存；板上只有片上8MB SDRAM，无外部DDR |
| 原语/IO | 本模块无需厂商原语、板级引脚；TD模块探针不得当成烧录bit |
| 吞吐 | 每有效周期一像素，固定0拍延迟 |
| 预算 | 目标600 LUT、0 DSP、0 ERAM；超目标须解释，全视觉不超4000 LUT/10 DSP/12 ERAM |

## IP复用评估

已查阅 `docs/HARDWARE_TOOLCHAIN_REFERENCE.md` 第4.1节；不是对未安装候选IP的实际调用验证。

| 候选 | 属性 | 可替代部分 | 决策 |
|---|---|---|---|
| RAM/ROM 1.0 | 明文 | 24×16位配色 | 不例化；小常量选择即可，避免块存储浪费 |
| Scaler 1.0 | 明文 | 图像缩放 | 不选；本任务从坐标直接生成图形 |
| Video_In_to_AXI4_Stream 1.0 | 明文 | AXIS桥接 | 本任务不封装；主线另评估，保留已验证语义 |
| FFT/FIR 1.0 | 明文 | 音频分析 | 本任务能量已输入，不选 |
| Video NPU 1.1 | 加密 | 图像计算 | 不选；比较/查表不需复杂IP |

已查阅，无匹配八柱应用渲染的直接IP。自研仅限应用层像素逻辑；不得搬运IP源码。

## 依赖

RTL无外部模块依赖。时序依据为 `../task_011_hdmi_video_white_screen_fix/rtl/video_timing_data.v`（正式立项后相对路径），真实端口 `I_clk,I_rst,O_hs,O_vs,O_de`，低有效HS/VS；禁止修改其接口或实现。具体字段与源文件指纹见 `reference/UPSTREAM_FACTS.md`。

当前候选任务仍在visual_workspace；上游路径以reference记录的项目根路径解析。不得因相对路径尚未迁移就猜测端口。

## 验收结果（目标）

- 编译0警告0错误；所有契约场景有真实断言、失败返回非零。
- 几何全像素比对，协议检查每帧307200次有效采样、480个有效行、每行640像素。
- 帧内快照稳定、V-Blank参数提交、复位等待VS、极值和异常时序符合接口。
- 模块TD综合/时序报告可重跑，25.2MHz收敛，不增加DSP/ERAM；未做板级集成时明确没有可用上板bit。
- 后续集成门槛：A源为Task011已验证彩条，B源为八柱；除源/必要适配外PLL、PHY、IP参数、音频和约束保持相同。对valid/SOF/EOL逐拍等价检查，data按各自图形期望检查，不能要求不同画面data相同。RGB565扩展端点0000→000000、FFFF→FFFFFF、F800→FF0000。
- 上板独立记录：八柱随假能量变化、三种配色和幅度/冻结，冷启动与至少30分钟观察；60分钟长稳及多接收端完成前不称可交付稳定性。真实TF/音频不属于本任务。

## 产物清单

| 路径 | 责任与内容 |
|---|---|
| TASK_BRIEF.md / INTERFACE_SPEC.md / VERIFICATION_CONTRACT.md / START_PROMPT.md | 规格方提供 |
| doc/spec/behavior_spec.md | 已提供行为规格；实现方仅在批准范围内补充实现说明 |
| reference/eight_bars_geometry.json / reference/FRAME_EVENT_VECTORS.md / reference/UPSTREAM_FACTS.md | 固定几何、帧事件期望与依赖事实，只读 |
| rtl/eight_bar_renderer.v | 实现方提供 |
| tb/tb_top.v / tb/dut_inst.vh / tb/scenario_matrix.md / tb/handoff_packet.md | 实现方提供 |
| sim/run.sh / sim/compile.log / sim/sim.log / sim/sim_result.json | 实现方提供；可补Windows启动脚本 |
| doc/compile/check_report.md / doc/compile/run_report.md | 实现方提供 |
| td_run/run.tcl / td_run/resource_report.txt / td_run/timing_report.txt | 实现方提供模块级综合及约束说明，不能伪造板级bit |
| FINAL_ACCEPTANCE.md | 独立验收通过后由验收方生成，当前不创建 |

## 六维设计审查

| 维度 | 结论与检查 |
|---|---|
| 功能边界 | 只生成像素；不重写时序、HDMI、存储或音频 |
| 时钟域 | 单25.2MHz；复位同步释放，多位能量上游握手 |
| 资源占用 | 估算≤600 LUT/130寄存器/0DSP/0ERAM；TD实测待实现 |
| 时序收敛 | 0拍组合，约39.68ns预算；负余量则退回规格评估，禁止隐式加延迟 |
| 稳定性 | 场快照、饱和计数、复位重新对帧；有全零/越界等异常测试 |
| 可扩展性 | 保持8能量+RGB565接口，后续效果替换须重审资源与延迟，不预留无用功能 |
