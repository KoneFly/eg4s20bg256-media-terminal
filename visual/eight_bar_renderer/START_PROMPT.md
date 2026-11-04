# 八柱渲染器启动说明

仅供任务包通过中间检验并由验收方移入 `iccoder_workspace/tasks/task_XXX_*/` 后使用。当前目录是候选包，不在这里自行启动实现或生成验收报告。

## 必读文档

1. `../../LESSONS_LEARNED.md`
2. `../../ACCEPTANCE_SOP.md`
3. `../../WORKSPACE_TEMPLATE.md`
4. 本目录 `TASK_BRIEF.md`
5. 本目录 `INTERFACE_SPEC.md`
6. 本目录 `VERIFICATION_CONTRACT.md`
7. 本目录 `doc/spec/behavior_spec.md`
8. 本目录 `reference/UPSTREAM_FACTS.md`、`reference/eight_bars_geometry.json` 与 `reference/FRAME_EVENT_VECTORS.md`

前3项按正式任务位置解析。当前候选包阅读时，应从项目根读取 `iccoder_workspace/` 下同名只读文件；不要创建假的LESSONS文件使错误路径看似存在。

## 上游依赖说明

时序基线 `../task_011_hdmi_video_white_screen_fix/rtl/video_timing_data.v` 的真实端口为 `I_clk,I_rst,O_hs,O_vs,O_de`。I_rst高有效，HS/VS低有效；将来连接时复位极性需显式转换。

基线 `video_source_b_fixed.v` 端口包括 `I_clk,I_rst,I_vs,I_de,axis_s_ready,axis_s_user,axis_s_valid,axis_s_last,axis_s_data[23:0]`；它内部生成彩条，没有pixel输入。**以源码为准，不要凭示例代码猜测**。本模块不实例化或改动这个源。

上游实现/端口禁止修改；当前输出RGB565，未来主线另立像素适配任务。本任务没有AXIS或ready端口。

## 分阶段执行计划

1. 核对规格与黄金表。若0拍时序或接口条件无法满足，先报告具体冲突，禁止擅改端口。
2. 根据已经定义的行为细化实现说明及独立黄金使用方式，再写RTL；只用整数和常量查表。
3. 完成编译检查，保证0警告0错误。
4. 完成独立TB与V01—V14场景、看门狗、真实输出检查；独立运行脚本生成日志与JSON。
5. 模块TD综合及有约束的25.2MHz时序检查；记录资源、时序边界和未覆盖的板级路径。
6. 交付报告、场景矩阵和handoff_packet；说明最高证据等级与未完成的主线集成/上板。

## 不要做的事

- 不越出正式任务工作区写文件；reference和项目规范只读。
- 不改HDMI时序/PLL/PHY/加密IP，不复制IP源码。
- 不新增端口、不引入浮点/除法/动态存储，不加未协商的像素延迟。
- 不把TB公式与RTL写成同一套算法自证；不使用旧仿真二进制。
- 不自行立项、编号、调用其他实现者或执行git提交/分支操作。
- 不创建 `FINAL_ACCEPTANCE.md`，不声称没有实测的上板PASS。
