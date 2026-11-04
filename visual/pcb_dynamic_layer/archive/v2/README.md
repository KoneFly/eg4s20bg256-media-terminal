# pcb_dynamic_layer V2 历史归档

> 归档日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方

用户已批准 W1 整体出列，当前包只推进 W2 多周期版。V2 的 351 个原文件在出列前完整复制并逐个 SHA256 校验，清单为 archive_manifest.json；旧根入口另外保存在 START_PROMPT.md。

rtl/tb/reference/sim/doc/td_run 按当时相对目录保留，包含 W1/W2 原版实现、黄金、日志、配置及独立 TD 数字。原测量报告在 doc/output/V2_MEASUREMENT_REPORT.md，最终 V2 TD 在 td_run/v2/w1 与 w2。

W1 因资源和构建期限超标停止投入；解析式绘制只是二期候选，未承诺实施。本目录是历史证据，不纳入当前 W2 验证矩阵。归档脚本含原任务根相对依赖，恢复执行时应另建复现副本并按原目录关系提供只读上游，不能直接覆盖当前活动文件。
