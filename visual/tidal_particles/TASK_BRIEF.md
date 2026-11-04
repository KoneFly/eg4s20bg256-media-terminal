# M5 潮汐星流任务包

状态：候选，待中间检验与正式编号。用户反馈后以完整环形频谱为主、16状态粒子为动势；下落音块/地形在原型保留为后续变体。

## Task Summary

实现一个640×480 RGB565八方向能量环和16槽有限粒子渲染器，固定0拍像素输出，可替换现有内容渲染器。

## Scope

输入8路已同步能量和外部视频时序，输出像素及valid。场提交更新定点环能量快照、16粒子位置/速度/寿命、共享LFSR。做RTL/TB/脚本/模块TD证据。不实现浏览器64段平滑线、下落方块、伪3D地形、音频分析、HDMI、跨域、帧缓存或板级顶层。至少覆盖零能量、满能量、粒子叠盖、12场寿命、种子可复现、同沿按键、复位和坐标越界。

## 硬件约束（Hardware Constraints）

| 项 | 约束 |
|---|---|
| 器件 | EG4S20BG256，25.2MHz像素域 |
| 内存 | 不使用外部DDR、片上SDRAM、ERAM或帧缓存 |
| 原语/IP | 0DSP、0BRAM目标，不例化新PLL/PHY |
| 接口 | 与013/025/030的8能量输入、RGB565/valid端口形状同构 |
| 吞吐 | DE有效区每拍1像素，0拍组合输出 |
| 模块估算 | ≤1100 LUT / ≤650 REG / 0DSP / 0ERAM |
| 主线底数 | 036 P1报告12684 LUT/7004 REG/7054 slices（71.98%）、14 DSP、45 BRAM9K；SWNS +0.099ns |

模块估算不能推出完整工程时序或资源PASS。036 P2/P3仍会增资源，**腾出的未来面积不得预支**。036稳定且030/M4上板后再做单变量M5集成与全片TD。

## IP复用评估

已按`docs/HARDWARE_TOOLCHAIN_REFERENCE.md` §4.1核对。

| 候选 | 属性 | 用途 | 决策 |
|---|---|---|---|
| ROM 1.0 | 明文 | 3×8 RGB565主题表 | 小常量case实现；TD若推ROM需登记 |
| Soft_FIFO 3.0 | 明文 | 粒子状态队列 | 不选；16槽固定寄存器，可直接并行比较 |
| CORDIC 1.0 | 明文 | 角度/圆周坐标 | 不选；定点近似距离+八方向判定即可 |
| Video NPU 1.1 | 加密 | 图像特效 | 不选；验证代价和资源均不合适 |

调用IP应例化并登记，不把明文源码搬入交付RTL。

## 调试与可观测性设计

有画面但无外环：看8能量快照、方向band、D/R；环正常但粒子不动：看frame_commit、cursor、LFSR；粒子左右反向：看vx signed；静音仍不断发射：看阈值与014衰减；整幅错位：看Task020/030坐标相位。

最小ChipWatcher探针建议：frame_commit(1)、seed[15:0]、cursor[3:0]、slot0{x[9:0],y[8:0],age[3:0],active}、band[2:0]、pixel_rgb565[15:0]、pixel_valid(1)。优先触发frame_commit或slot0发射；Read Design后标记，不在最终源码留下调试属性。探针最多两轮，随后回到A/B及固定锚点bit。模块无错误码输出，板级首次失败码由后续集成任务做sticky编码。

## 依赖

- Task020/030：已验收视频坐标相位与内容端口；030 M4模块源只读，板级先于M5。
- Task014包络、Task017假能量、Task015 RGB扩展、Task016 AXIS：集成层只读复用。
- Task024八段分析：输出侧与017同构，真实音频集成后置，不在本任务直接接PCM。
- Task036：主线面积/时序门槛；当前SWNS极薄，集成必须在其稳定之后。

以正式源码及`reference/UPSTREAM_FACTS.md`指纹为准，不凭本任务示例猜端口。

## 验收结果（目标）

P01–P14场景全部PASS；固定首两帧状态与21像素锚一致；LFSR/优先级/寿命通过独立可观察判据。编译0错0警。模块TD完整报告LUT/REG/DSP/BRAM、Setup/Hold WNS及违例端点；不得美化负裕量。集成时A源030，B源只换M5内容，先算两bit资源/时序与引脚差异再上板。用户实物观察通过前不称M5硬件PASS。

## 产物清单

| 路径 | 内容 |
|---|---|
| 本目录四份根文档与doc/spec/behavior_spec.md | 规格方候选 |
| reference/m5_particle_vectors.json、UPSTREAM_FACTS.md | 固定锚与上游证据 |
| rtl/tidal_particle_renderer.v | 实现方提供 |
| tb/tb_top.v、dut_inst.vh、scenario_matrix.md、handoff_packet.md | 实现方提供 |
| sim/run.sh、compile.log、sim.log、sim_result.json | 实现方提供；基于SIM_RUN_TEMPLATE.sh |
| doc/compile/check_report.md、run_report.md、td_report.md | 实现方提供 |
| constraints/*.sdc、td_run/* | 模块TD与时序报告，非可烧bit |
| FINAL_ACCEPTANCE.md | 验收方独立通过后生成，当前不创建 |

## 重要提醒

浏览器的64点圆形线比本任务八方向定点环更平滑；**像素黄金只以“硬件形态”按钮显示的版本为准**。任何实现若偷偷调用sin/cos/sqrt或用旧Task013 x相位，即使视觉上“差不多”也不合格。视觉主题/粒子色表是本项目常量，不复制外部仓库素材。

## 六维设计审查

| 维度 | 结论 |
|---|---|
| 功能边界 | 仅内容渲染；030/M4、036主线和014/024不在此包修改 |
| 时钟域 | 单25.2MHz；复位同步释放；8路输入同域 |
| 资源 | 16槽约512状态位，目标≤1100LUT/650REG/0DSP/0ERAM；全片待集成实测 |
| 时序 | 16槽并行像素命中与整数距离择色，39.683ns；无私加延迟 |
| 稳定性 | 有界状态、寿命12场、cursor/LFSR固定、零能量停止发射 |
| 可扩展性 | 同构RGB565内容端口，可与030内容源在主线单变量切换 |
