# M2 八路平滑包络

候选任务包，等待中间检验与正式立项；不替代实现方编写RTL。

## Task Summary

实现八路帧级可调上升/下降包络，输出稳定能量供已验收八柱模块消费。

## Scope

输入clk/rst/tick、8路打包能量与运行时控制；输出8路包络。实现RTL/TB/脚本/模块TD。排除像素渲染、HDMI、CDC、物理按键映射和主线修改。必须处理0/255、1LSB尾部、hold/bypass优先级、无tick输入变化、帧间目标反转。

## 硬件约束（Hardware Constraints）

| 项 | 约束 |
|---|---|
| 芯片/时钟 | EG4S20BG256，外部25.2MHz，不新增PLL |
| 内存/IO | 仅64位能量状态及复位寄存器，无SDRAM/DDR/板级引脚 |
| 位宽 | lane8位，中间量9位，打包64位 |
| 资源 | 估算≤500 LUT/66寄存器/0DSP/0ERAM；全视觉预算4000 LUT/10DSP/12ERAM |

## IP复用评估

依据已读HARDWARE_TOOLCHAIN_REFERENCE §4.1，属性来自清单，不代表本任务实际例化测试。

| 候选 | 属性 | 可替代部分 | 决策 |
|---|---|---|---|
| FIR 1.0 | 明文 | 滤波计算 | 不选；当前是方向相关帧级追随器，不是固定系数FIR |
| RAM/ROM 1.0 | 明文 | 状态/步长表 | 不选；64位状态与4档偏置可直接寄存器/逻辑实现 |
| Divider 2.0 | 明文 | 比例计算 | 不选；2幂除数直接移位 |

已查阅，无直接匹配本包络事件语义的IP，应用逻辑自研。不得复制IP源码。

## 依赖

模块无外部RTL依赖。集成消费者是正式目录 `task_013_eight_bar_renderer/rtl/eight_bar_renderer.v`，真实能量端口band0_energy..band7_energy均8位，clk/rst_n同名；VS下降沿锁存能量。不得修改其接口或实现。像素与参数行为以正式M1契约为准，不用旧交接快照推翻验收版。M1验收来源见visual_workspace/reports/M1_RTL_ACCEPTANCE.md。

## 验收结果（目标）

固定向量与全部测试通过、编译0警告0错误，独立重跑与变异证伪生效；25.2MHz模块STA收敛，资源报告完整。M1同沿读取旧包络的逐帧延迟需明确验证；像素输出0拍属性不改变。HDMI上板不阻塞M2模块交付，但不得声称硬件PASS。

## 产物清单

| 路径 | 内容 |
|---|---|
| 四份任务根文档、doc/spec/behavior_spec.md | 候选规格已提供 |
| reference/envelope_vectors.json | 固定手算期望，只读 |
| rtl/energy_envelope.v | 实现方提供 |
| tb/tb_top.v、dut_inst.vh、scenario_matrix.md、handoff_packet.md | 实现方提供 |
| sim/run.sh、compile.log、sim.log、sim_result.json | 实现方提供可重跑证据 |
| doc/compile/check_report.md、run_report.md | 实现方提供 |
| td_run/run.tcl、resource_report.txt、timing_report.txt | 模块综合/STA，非板级bit |
| FINAL_ACCEPTANCE.md | 仅验收方通过后创建 |

## 六维设计审查

| 维度 | 结论 |
|---|---|
| 功能边界 | 只处理能量，不改M1像素/HDMI |
| 时钟域 | 单25.2MHz，内部复位同步释放；CDC归上游 |
| 资源 | 新增估算500LUT/66寄存器/0DSP/0ERAM，TD待验证 |
| 时序 | 差值→2位变移位→加减→寄存器，39.68ns；无多周期假设 |
| 稳定性 | 最小步长1，单调不越界，hold优先、无tick不变 |
| 可扩展性 | 攻击/释放配置独立；不占用冻结的M1保留键位 |
