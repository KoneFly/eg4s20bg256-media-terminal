# ⚠️ 本目录已废弃 — M6-S4 由 task_055 承担

> 2026-10-02 说明（浮浮酱）：本文件原为 M6-S4 的新立项启动词，经复核发现
> **`task_055`（M6 频谱前端 · 自研 4096 点 FFT）已经存在且规格完整**
> （主人 2026-09-30 已裁定"自研 + 落 32K"路线），本包与之重复，**不要使用**。

## 正确的 S4 启动入口

```
iccoder_workspace/tasks/task_055_selfmade_fft/doc/brief/START_PROMPT.md
```

## 背景（为什么 055 就是 S4）

- `visual_workspace/spec/M6_PCB_PORTING_PLAN.md` §3：S4 = 频谱前端（先探针后实现）；
- 探针已由 task_048（FFT IP 可行性）/ task_049（ERAM32K 映射）完成，结论：
  厂商加密 IP 的 RAM 无法引导到 32K 池（17 块全落 9K）、9K 池装不下
  ⇒ **主人 2026-09-30 裁定：走自研 + 落 ERAM32K**；
- ⇒ `task_055` = S4 的实现包（把 `pcb_spec_fixed.js` 逐位翻译成 RTL）。

## 保留本目录的原因

登记本次"重复立项"教训：**新立项前必须先扫 `visual_workspace/rtl_handoff/` 与
`iccoder_workspace/tasks/` 的现有包**（本项目按"一任务一模块"原则立项、编号会跳跃，
不要凭印象新建）。本次由浮浮酱自查发现并修正。
