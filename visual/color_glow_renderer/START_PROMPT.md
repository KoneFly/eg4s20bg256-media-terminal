# M3 色光渲染器启动说明

候选包通过中间检验、移入正式任务并由用户启动实现方后执行。

## 必读文档

1. `../../LESSONS_LEARNED.md`
2. `../../ACCEPTANCE_SOP.md`
3. `../../WORKSPACE_TEMPLATE.md`
4. 本目录TASK_BRIEF.md、INTERFACE_SPEC.md、VERIFICATION_CONTRACT.md
5. doc/spec/behavior_spec.md、reference三份文件

## 上游依赖

集成相位权威是 `../task_020_visual_hdmi_integration/rtl/eight_bar_renderer.v`（FE782BCA…），不是Task013原始版本。能量来自Task014 `envelope_out[63:0]`，lane0=[7:0]；下游Task015接RGB565/valid，Task016封装AXIS。以源码为准，不要凭示例代码猜测，所有上游只读。

## 分阶段执行计划

核对固定黄金与源码相位→完成RTL→编译检查→独立TB CG01–CG17→五类变异证伪并保留历史日志→模块TD/STA→交付报告。按TASK_BRIEF完成失败分支与可观测性设计，在handoff_packet列出最小ChipWatcher探针、A/B预期映射和ADC核查表。

## 不要做的事

不跨任务写入、不改M1/M2/Task020，不实现HDMI/伪3D/M5状态粒子/音频，不加帧缓存/浮点/乘除法，不整体右移RGB565，不新增端口或像素延迟，不用全程invalid伪装背景，不复制厂商IP源码，不创建FINAL_ACCEPTANCE。不得留下未清理的MARK_DEBUG标记，不得假设上板后能靠画面反推全部内部状态。
