# M2 启动提示

候选包通过中间检验、移入正式task目录并由用户启动实现方后使用。

## 必读

1. `../../LESSONS_LEARNED.md`
2. `../../ACCEPTANCE_SOP.md`
3. `../../WORKSPACE_TEMPLATE.md`
4. TASK_BRIEF.md、INTERFACE_SPEC.md、VERIFICATION_CONTRACT.md
5. doc/spec/behavior_spec.md、reference/envelope_vectors.json

前三项按正式task位置解析，候选目录阅读时使用项目根iccoder_workspace下同名只读文件。

## 上游依赖

`../task_013_eight_bar_renderer/rtl/eight_bar_renderer.v`：band0_energy..band7_energy为8位，clk/rst_n，vsync低有效下降沿锁存。以源码为准，不要凭示例代码猜测。不得修改M1接口或实现；同沿接入明确产生一帧延迟。M1的KEY3及sw高位保留。

## 分阶段执行

读规格和固定黄金→补充实现说明→RTL→编译检查→独立TB→真实仿真与变异证伪→模块TD/STA→交接报告。遇规格冲突先报告，不能擅改接口。

## 不要做的事

不跨任务写入，不修改reference/项目规范，不实现HDMI/CDC/板级控制，不复制IP源码，不新增端口，不修改M1，不把低频tick用作放宽时序理由，不创建FINAL_ACCEPTANCE，不声称未实测的上板PASS。
