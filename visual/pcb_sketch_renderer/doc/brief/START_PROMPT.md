# START_PROMPT — pcb_pixel_renderer（给执行方）

你在实现 **M6 PCB 线稿频谱** 的**像素渲染器**：把「16bit 标签 + 16bit 图像像素」的逐拍像素流，
按冻结的状态表合成为最终 RGB565。这是视觉子系统上板链路里唯一负责「逐像素着色」的模块。

---

## 必读文档（按顺序）

| # | 文档 | 为什么读 |
|---|---|---|
| 1 | `../../TASK_KICKOFF.md`（`iccoder_workspace/TASK_KICKOFF.md`） | **工作区唯一必读**：铁律 / 三档模型 / bit 纪律 / 代码合规 / 清理纪律 / §10 文档规范 |
| 2 | `doc/brief/TASK_BRIEF.md` | 范围、硬件约束、IP 复用评估、六维审查、产物清单 |
| 3 | `doc/brief/INTERFACE_SPEC.md` | **冻结契约**：端口、标签编码、**状态表内存图**、逐类着色算术、输出级公式 |
| 4 | `doc/brief/VERIFICATION_CONTRACT.md` | 9 个黄金场景、TB 架构要求、验收门槛 |
| 5 | `reference/UPSTREAM_FACTS.md` | 上游事实（标签/状态表的来源文件与行号，**以源码为准**） |
| 6 | `spec/M6_PCB_SKETCH.md`（`visual_workspace/spec/`） | 效果规格（本模块实现的算术的唯一来源） |

> 通用纪律（上板前置、三档模型、清理等）由 `TASK_KICKOFF.md` 兜底，本文不再重复。

---

## 模型选择建议

| 档位 | 建议 |
|---|---|
| **标准档** | **推荐**。接口已冻结、黄金齐备（9 场景 × 全帧逐位）、判据清晰，属"契约完整、判据清晰"的单模块新开发 |
| 强推理档 | 仅当出现"逐像素对不上但不知差在哪"时升级（先用 `TASK_BRIEF.md §调试与可观测性设计` 的探针定位） |

---

## 上游依赖（以源码为准，不要凭示例猜测）

| 上游 | 路径 | 你需要知道的 |
|---|---|---|
| 黄金向量 | `reference/vectors/` | 9 个用例目录 + 共用 `label.bin`；格式见 `reference/UPSTREAM_FACTS.md` §向量格式 |
| 黄金生成器 | `reference/gen_vectors.cjs` | 由 JS 参考模型生成；**只读**，不得修改（改动须由浮浮酱重出并登记） |
| 参考模型 | `visual_workspace/prototype/pcb_model.js` | `pcbRender()` 是黄金的算法来源；**只读** |
| 标签图来源 | `visual_workspace/prototype/pcb_labels.js` | 标签编码的权威定义；**只读** |

**端口真实性**：本模块是**新模块**，无上游模块端口需要拼接；但**状态表写口的语义**必须与将来的 `pcb_frame_updater`（S3）一致 ——
故 `INTERFACE_SPEC.md` 的内存图是**双向冻结契约**，不得自行调整字段位置。

---

## 分阶段执行计划

| 阶段 | 内容 | 完成判据 |
|---|---|---|
| **P1 骨架与解码** | 端口/时钟/状态表 BRAM（真双口）/标签 class 解码 + 地址生成 | 编译 0 错 0 警；`all_zero` 场景的静态部分可跑通 |
| **P2 逐类着色** | class 1~7 的 dark/light 计算（含脉冲三槽、彗星尾、柱/节点查表） | `boot_done` + `grow_half` 全帧逐位 PASS |
| **P3 输出级** | 柱形图平面 → 3×3 膨胀（行→列，2 行缓存）→ 径向/通道索引（逐行增量）→ 调色 → 合成 | `play_*` + `saturate` 场景 PASS |
| **P4 叠加通道** | `ov_on` 分支：底图展开、Y 判据、3/8 深色线、`m` 四档混合、柱形图带压暗 | `overlay_*` 场景 PASS |
| **P5 协议与时序** | 固定延迟断言、复位重入、跨域写读一致性 | 契约 §1 协议检查 4 项 PASS |
| **P6 TD 综合** | 独立综合，如实报告资源与 WNS | `doc/output/td_report.md` |

**每个阶段结束后**：更新 `doc/output/behavior_spec.md`（状态机/流水线级数/延迟），
并在 `run_report.md` 记录该阶段跑通的场景与失配数。

---

## 不要做的事

1. ❌ **不要修改 `INTERFACE_SPEC.md` 的端口或状态表内存图** —— 那是与 S3 的双向冻结契约；
   确有需要先向浮浮酱提出（不得自行调整后让 TB 跟着改）。
2. ❌ **不要去实现音柱粒子与柱顶连线** —— 那是后续任务 S2b；本任务的黄金向量已把它们置零，
   自己实现会导致逐位比对失败。
3. ❌ **不要用移位近似替代 `(x * ov_k) >> 8`、`(255-r)*w>>8`、`/3`、`/90` 等除法** ——
   黄金要求逐位相等，近似必失败。
4. ❌ **不要从 RTL 公式反推黄金** —— 黄金由 `reference/gen_vectors.cjs` 从 JS 模型独立生成（LESSON-001）；
   若发现黄金与 `INTERFACE_SPEC.md` 不一致，**停下来报告**，不要改黄金去迁就实现。
5. ❌ **不要修改 `reference/` 下任何文件**（只读）。
6. ❌ **不要在源码留 `MARK_DEBUG` 痕迹** —— 调试用「Read Design 后界面标记」；若必须留痕，交付前清理。
7. ❌ **不要抽样比对** —— 全帧 307,200 像素逐位是核心判据。
8. ❌ **不要跑与验收无关的长仿真** —— 按 `VERIFICATION_CONTRACT §4` 的档位来。
9. ❌ **不要碰 `visual_workspace/prototype/`**（参考实现）与主线工程 `iccoder_workspace/tasks/task_043_*/`。
