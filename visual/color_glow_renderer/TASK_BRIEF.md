# M3 色光渲染器任务包

状态：待中间检验；未正式编号。M1/M2及Task020上板基线只读。

## Task Summary

实现与M1端口同构的RGB565光谱矩阵渲染器，用三套色盘、四级柱内渐变、发光栅格、无状态纹理亮点和最大7像素有限光晕升级八路包络画面。

## Scope

输入视频时序、8路包络能量及运行时控制，输出0拍RGB565像素和valid。实现独立RTL/TB/脚本/模块TD证据。排除M2、RGB888、AXIS、HDMI、PLL、假能量、伪3D、拥有位置/速度状态的M5粒子、真实音频和板级顶层修改。边界必须覆盖0/255能量、四档光晕、三主题、栅格间隔、四级渐变、亮点帧相位、冻结、同沿按键、非法时序饱和及集成相位。

## 硬件约束（Hardware Constraints）

| 项 | 约束 |
|---|---|
| 芯片/时钟 | EG4S20BG256；25.2MHz像素域；不新增PLL |
| 数据 | 8×8bit能量、RGB565；有效区每拍一像素、0拍输出 |
| 存储/算术 | 0 SDRAM、0 ERAM、0 DSP；无浮点/任意除法/全屏读写 |
| IO | 模块无板级引脚；后续集成复用Task020已修正ADC |
| 资源 | ≤1200 LUT、≤160 REG；替换M1后视觉链估算≤1817 LUT，口径不含HDMI加密IP |

## IP复用评估

已查阅HARDWARE_TOOLCHAIN_REFERENCE §4.1。

| 候选 | 属性 | 可替代内容 | 决策 |
|---|---|---|---|
| ROM 1.0 | 明文 | 24项核心色盘 | 不选；384bit常量case更小且易独立仿真 |
| RAM 1.0 | 明文 | 帧/行缓存 | 不选；坐标直接生成，无缓存需求 |
| Video NPU 1.1 | 加密 | 图像增强 | 不选；验证成本高且功能过量 |
| Scaler 1.0 | 明文 | 缩放 | 不选；固定640×480坐标生成 |

已查阅，无匹配有限矩形光晕的IP；应用层自研，不复制IP源码。

## 调试与可观测性设计

失败分支可区分：无信号优先对照Task020 A源及ADC；有画面但错位看坐标/AXIS相位；颜色错看theme/core/015；幽灵光看height与layer；不切换看pending/active提交。

模块探针建议：`x_r[9:0]`、`y_r[9:0]`、`frame_commit`、`frame_phase[8:0]`、`energy_snapshot[63:0]`（调试时可先只取lane0/7）、`active_theme[1:0]`、`active_glow[1:0]`、`pixel_rgb565[15:0]`。建议触发`frame_commit`或`x_r==76 && y_r==top0`；最小位宽优先。

后续集成A/B：A=Task020修复版八柱位流，B=M3替换渲染器；其余014/015/016/017、HDMI IP、PLL/PHY、音频和ADC逐份SHA锁定。上板前冻结预期映射：A正常/B无信号→集成/约束；A正常/B锐利无光→glow默认/壳层；A/B均正常且B有色光→通过。LED保留Task020四灯身份；需要mosaic时另用LED相位指示。ChipWatcher最多2轮，不能收敛则转A/B源与固定主题bit，不无限投入。

不得在最终源码留下MARK_DEBUG；优先Read Design后添加探针。模块无错误输出，不虚构sticky失败码；板级失败码由集成任务定义。

## 依赖

- Task020 `rtl/eight_bar_renderer.v`：上板A源及集成相位权威，SHA见reference；不得修改。
- Task014 energy_envelope：输出64位包络，lane0低8位；不得修改。
- Task015/016：RGB扩展与AXIS适配；后续集成只读复用。
- Task017：P128假能量；后续上板内容源。

真实端口、指纹和ADC事实见 `reference/UPSTREAM_FACTS.md`。以源码为准，不凭旧M1交接快照猜测。

## 验收结果（目标）

- CG01–CG17全部PASS，0错误0警告，结构化结果真实生成；全帧固定栅格/壳层黄金与21个固定锚点一致。
- 至少5类变异被检出：核心边界、栅格间隔、亮点帧相位、整体16位移位串色、Task013旧x相位。
- TD模块综合25.2MHz 0违例，≤1200 LUT/160 REG/0DSP/0ERAM，无宽泛时序例外。
- 集成前证明端口同构；集成任务以Task020为A源，ADC必须D2=E1、D1=F1、DDC 8mA+PULLUP。
- 模块验收不宣称上板；M3完成需B源上板可辨认三层光效，至少默认主题/柔光得到目视证据。

## 产物清单

| 路径 | 内容 |
|---|---|
| TASK_BRIEF/INTERFACE_SPEC/VERIFICATION_CONTRACT/START_PROMPT | 候选规格方提供 |
| doc/spec/behavior_spec.md | 精确几何、色表、相位 |
| reference/m3_color_glow_vectors.json、FRAME_EVENT_VECTORS.md、UPSTREAM_FACTS.md | 固定画面/事件黄金与只读上游事实 |
| rtl/color_glow_renderer.v | 实现方提供 |
| tb/tb_top.v、dut_inst.vh、scenario_matrix.md、handoff_packet.md | 实现方提供 |
| sim/run.sh、compile.log、sim.log、sim_result.json、mutation日志 | 实现方提供 |
| doc/compile/check_report.md、run_report.md、mutation_report.md | 实现方提供 |
| constraints/color_glow_renderer.sdc、td_run/run.tcl及三类报告 | 实现方提供模块TD证据 |
| FINAL_ACCEPTANCE.md | 仅验收方通过后创建 |

## 重要提醒

Task020的FE782BCA版本才是集成相位权威；Task013原始A5FB版本仅代表旧TB相位。背景非黑，因此全程invalid不能伪装零能量PASS。默认glow=2，不依赖板级开关。ADC约束错误曾造成真实无信号，后续集成必须逐引脚对照。

## 六维设计审查

| 维度 | 结论 |
|---|---|
| 功能边界 | 独立内容渲染器，保留014/015/016/017和HDMI边界 |
| 时钟域 | 单25.2MHz；复位同步释放；输入已同域 |
| 资源 | 目标1200LUT/160REG/0DSP/0ERAM；视觉链替换后≤1817LUT估算 |
| 时序 | 0拍比较/色表/位移；39.683ns；集成级再锁相位 |
| 稳定性 | 场快照、坐标饱和、零能量无幽灵光、配置V-Blank提交 |
| 可扩展性 | 同构接口让M1/M3作为内容库切换；M4/M5沿用同一输出边界 |
