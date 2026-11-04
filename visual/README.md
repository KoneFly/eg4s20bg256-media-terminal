# rtl_handoff —— RTL 任务包交接区

本目录存放由视觉方编写、**等待中间检验**的 RTL 任务包。

---

## 规则

1. 任务包写在 `rtl_handoff/<任务名>/`，结构按 `iccoder_workspace/WORKSPACE_TEMPLATE.md`
2. 通过中间检验后，由**验收方**移入 `iccoder_workspace/tasks/task_XXX_<名称>/` 正式立项
3. **立项后权威版本在 `iccoder_workspace/tasks/` 下**；本目录保留的快照仅供追溯，**不再修改**
4. 未通过检验的任务包留在本目录，按打回意见修订后重新提交

---

## 交接记录

| 任务包 | 状态 | 立项位置 |
|---|---|---|
| `eight_bar_renderer` | ✅ 中间检验通过（2026-09-11） | `iccoder_workspace/tasks/task_013_eight_bar_renderer/` |
| `energy_envelope` | ✅ 中间检验通过（2026-09-11） | `iccoder_workspace/tasks/task_014_energy_envelope/` |
| `color_glow_renderer` | ✅ 模块验收通过（2026-09-16） | `iccoder_workspace/tasks/task_025_color_glow_renderer/`；待上板集成 |
| `spectral_ridge_renderer` | ✅ Task030模块级交付；板级集成待036稳定 | `iccoder_workspace/tasks/task_030_spectral_ridge_renderer/` |
| `tidal_particles` | 历史候选：环＋16状态粒子，2026-09-25起不再代表M5优先方向 | 未立项，保留只读追溯 |
| `particle_terrain` | 历史横向堆叠地形参考；仅含128列黄金，未完成四份核心文档 | 未形成可提交的任务包；当前默认等高线见 `../spec/M5_CONTOUR_MAP_DIRECTION.md` |

M1/M2结论见既有报告；M3权威结论在Task025 `ACCEPTANCE_EVIDENCE.md`；M4以Task030正式工作区为准；M5以 `../reports/M5_THEME_REALIGNMENT.md` 的方向与证据分级为准，尚未提交中间检验。

---

*交接流程详见 `../HANDOFF_WORKFLOW.md`。*
