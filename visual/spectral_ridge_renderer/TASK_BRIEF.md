# M4 连续频谱脊线任务包

状态：候选，待中间检验。Task025已模块验收；Task020上板基线与正式任务只读。

## Task Summary

实现与M1/M3端口同构的连续频谱脊线渲染器，以8段能量插值生成波形、点阵云和两层地形回声，取消固定矩形音柱。

## Scope

实现单模块RTL/TB/脚本/TD：8路能量快照、分段有符号插值、三主题、四模式、点阵哈希、辉光和回声。排除024分析器、014包络、RGB/AXIS/HDMI、音频播放、字幕、转场、状态粒子和板级顶层。覆盖上升/下降斜率、band7末段、静音、模式、主题、冻结、帧相位、集成坐标和异常时序。

## 硬件约束（Hardware Constraints）

| 项 | 约束 |
|---|---|
| 芯片/时钟 | EG4S20BG256；25.2MHz；不新增PLL |
| 吞吐 | 有效区每拍一像素；0拍组合输出 |
| 算术 | 允许1个9×6有符号乘法（≤1 DSP）；无除法/浮点 |
| 存储 | 0 ERAM、0 SDRAM访问、无帧缓存 |
| 资源 | ≤1000 LUT/180 REG/1 DSP；与024整链估算约3807 LUT/5 DSP |
| IO | 模块无引脚；后续集成复用Task020返工ADC |

## IP复用评估

已查HARDWARE_TOOLCHAIN_REFERENCE §4.1。

| 候选 | 属性 | 可替代内容 | 决策 |
|---|---|---|---|
| DSP原语 | 厂商原语 | `diff*frac` | 允许综合推断/例化1个；报告实际映射 |
| CORDIC 1.0 | 明文 | 曲线/坐标 | 不选；线性插值无需三角函数 |
| ROM 1.0 | 明文 | 色盘 | 不选；24项常量case更小 |
| RAM/Soft FIFO | 明文 | 高度表/缓存 | 不选；逐像素组合生成 |

## 调试与可观测性设计

失败分层：无信号→ADC/AXIS；整幅错1像素→Task020坐标相位；上升正常下降异常→signed diff；最后64像素突变→band7 e1；波形正确但无点→hash/density/mode；颜色错→色表/RGB移位。

最小探针：x/y各10位、frame_commit、phase低5位、band[2:0]、frac[5:0]、e0/e1各8位、height[7:0]、wave_y[8:0]、pixel565/valid。触发x=96或frame_commit。Read Design后标记优先，源码MARK_DEBUG交付前清理。ChipWatcher最多2轮，随后转A/B固定向量bit。

后续A/B：A=Task020上板八柱；B=017→014→M4。除渲染器外PLL/PHY/IP/015/016/017/014/ADC逐份SHA锁定。出bit前写预期映射；B若波形几何正确但点阵不动，定位phase；B无信号优先约束；A/B均无信号不归因M4。

## 依赖

- Task020：上板HDMI基线、坐标相位、修正ADC。
- Task014：8路包络；Task017：第一阶段假能量。
- Task024：第二阶段真实8段能量，输出格式同017；其≤34拍tick响应在集成任务处理。
- Task021：`wav_player_core`不暴露parser帧流；真实集成须在新顶层复用其parser/FIFO/I2S子模块，并在FIFO写握手拍广播样本，禁止修改021原件。
- Task025：复用已验收色表事实，不复用几何RTL。
- Task015/016：RGB扩展和AXIS，后续集成只读。

指纹与证据见reference/UPSTREAM_FACTS.md。以正式源码为准。

## 验收结果（目标）

- SR01–SR17全PASS，4幅全帧黄金、9高度锚、13像素锚一致，X/Z=0。
- 变异至少检出：diff符号错误、插值移位错误、band7回绕、phase移除、Task013旧x相位。
- TD 25.2MHz 0违例，≤1000 LUT/180 REG/1 DSP/0 ERAM；无无依据例外。
- 模块验收后先接017做A/B上板；几何/点阵可辨后再把024接入，不能同时更换内容和数据源后靠现象猜测。

## 产物清单

| 路径 | 内容 |
|---|---|
| 四份任务根文档、doc/spec/behavior_spec.md | 候选规格 |
| reference/m4_spectral_ridge_vectors.json、UPSTREAM_FACTS.md | 固定黄金与权威事实 |
| rtl/spectral_ridge_renderer.v | 实现方提供 |
| tb四件套、sim脚本/日志/JSON/变异日志 | 实现方提供 |
| constraints/spectral_ridge_renderer.sdc、td_run脚本/报告 | 实现方提供 |
| doc/compile三报告 | 实现方提供 |
| FINAL_ACCEPTANCE.md | 仅验收方生成 |

## 重要提醒

下降斜率必须是有符号算术；band7末段保持e7，不回绕band0。024与M4合并后LUT接近视觉预算边界，分层综合数字必须可复算。网络Task023与本任务无依赖。

## 六维设计审查

| 维度 | 结论 |
|---|---|
| 功能边界 | 只做内容渲染，数据源与显示链分离 |
| 时钟域 | 单pixel域；输入已同域 |
| 资源 | 1000LUT/180REG/1DSP/0ERAM目标；真实链约3807LUT/5DSP估算 |
| 时序 | 有符号乘法+比较，39.683ns；不私加流水 |
| 稳定性 | 场快照、静音无幽灵波、坐标饱和、band7守护 |
| 可扩展性 | 四模式共享同一高度；可与017/024互换数据源 |
