# P0 开工契约与黄金审计

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 状态：发现可复现的契约冲突，等待规格修订；P0 RTL/TB 尚未完成。

## 结论

按 START_PROMPT 的阅读顺序完成了任务纪律、W1/W2 契约、上游模型、M6 规格及 S2 打包的核查。当前任务包的行区段合并规则与逐像素黄金不能同时满足，不能直接按现有文本实现并宣称验收通过。

已新增可重复执行的 `sim/audit_startup.cjs`，只读加载既有参考函数。仅在内存中隔离其命令行入口，不修改签发脚本或参考算法。结果唯一来源为 `sim/startup_audit/audit_result.json`，源码身份及依赖 SHA256 也保存在该文件中。修订建议见同目录 `CONTRACT_CHANGE_PROPOSAL.md`。

## 已完成的检查

| 项目 | 结果 | 证据范围 |
|---|---|---|
| UPSTREAM_FACTS 登记的五个 SHA256 | 一致 | 效果规格、移植计划、模型、版图、标签 |
| T1/T2 默认打包 | 一致 | 6 场景，每场景 180 启动帧 + 120 播放帧，共 1800 帧；逐字对照 S2 原文 `packState()` |
| P 打包/解码 | 一致 | 同一批 1800 帧；1536 字、8 点历史、energy/life/active、保留位均检查 |
| P 有符号边界 | 一致 | x=-1024/1023、y=-512/511 的固定夹具，逐点独立解码 |
| 保护文件 SHA256 | 未变化 | 本轮使用的上游文件、签发契约和黄金脚本执行前后核对 |
| Verilator | 可用 | WSL Ubuntu：5.032，仅运行版本查询 |
| TD 控制台路径 | 存在 | `D:/AnLu/bin/td_commands_prompt.exe`，没有执行综合 |

以上属于黄金与契约自检。未验证 RTL 写口顺序、CDC、同步 RAM 相位、实际延迟、综合资源或板级行为。

## 可复现的算法/黄金冲突

### A1：相邻区段合并会改变像素亮度

依据 `INTERFACE_SPEC.md` §5.3，所有相交或相邻的区段必须合并，整个合并区段只保存最大 luma。然而 `gen_overlay_vectors.cjs::writeFrame()` 的像素文件直接使用未合并的光平面；其 `row_spans.json` 则把一段连续非零区域统一为最大亮度。

夹具 `nonuniform_luma`：一个 active 粒子，energy=240、life=110，history[h]=(110-3h,100)，其余柱/粒子为零。按生成的行区段还原颜色/alpha，会有 66 个像素的 alpha 与同次生成的像素黄金不同。首个失配在 (88,99)。具体数值见 JSON 的 `span_luma_conflict`。

因此这不是 DUT 算术问题。当前生成器自己导出的区段与像素文件已经不一致；修改 RTL 无法同时满足这两个参考。

### A2：无损分段后，饱和场景超出 4096 容量

对现有生成器的光平面，按相同亮度的连续像素构建区段，才能以一个 luma 字段逐位还原。审计覆盖现有六个状态场景的全部 1800 帧；`boot_low` 与 `play_low` 在现有生成器中使用相同刺激，不代表两个独立刺激种类。

饱和场景在第 6 个输入帧（frame=5，模型 f=6）已经超过容量，最大值也发生在合同规定的前 16 帧内。逐场景最大值、帧号见 JSON 的 `capacity`。旧审计所用的“连续非零区域数”不足以证明保存逐像素亮度后的容量。

另评估了重叠区段取 max 的表示，仍超出原容量；该方案已因容量原因排除。记录只作为审计证据，不作为新黄金。

### A3：屏外点先膨胀会向屏内贡献像素

`pcb_model.js::pcbRender()` 的 plot 先丢弃越界基础点，再对屏内光平面膨胀；本任务黄金 `addPixel()` 先扩展 3×3 邻域，再裁剪邻点。

夹具 `outside_before_dilation`：一个 active 粒子，所有历史点为 (-1,20)，energy=100、life=110，柱为零。上游模型在 (0,20) 输出 0，本任务黄金产生非零覆盖。复现时给上游渲染器传入全空标签，检查位置远离底部柱形图，避免静态层或 strip 干扰。

该输入位于 P 有符号坐标的合法表示范围内，属于明确要求覆盖的屏外裁剪用例。应由规格方统一裁剪顺序。

### A4：T2 全局字的 coreQ 边界溢入 ovK

本任务 `packMisc()` 把 coreQ=256 原样交给 `putByteWord()`，该辅助函数没有逐字节掩码。coreQ 的第 8 位进入 ovK 字节；当 ovK=255 时被掩盖。

边界 coreQ=256、ovK=0 时，地址 137 与 S2 `packState()` 不一致。期望/实际值见 JSON 的 `core_byte_spill`。应按 S2 原文对各字段执行 `&255`，不能改变 S2 字序或把 coreQ=256 改成 255。

## 需要澄清的接口和执行口径

1. **有效与命中分离**：`overlay_valid.bin` 实际保存命中掩码。`all_empty` 固定夹具的整帧该文件全为零；但接口要求完整输入帧对应的输出 `overlay_valid` 有 307200 个有效拍。TB 必须把它作为 hit 参考，或更正文件命名并另存 valid 序列。
2. **SOF/EOL 没有输出端口**：接口 §6 要求同延迟传递标记供合成级使用，但模块声明只有输入 `in_sof/in_eol`。应明确由集成侧延迟标记，或重新签发输出端口；不能自行扩展冻结端口。
3. **合体路径必须使用 hit**：合体验证输入列表/伪码只写 overlay_valid，没有 overlay_hit。由于非命中时 RGB565 可以保持上一值，按 valid 选择覆盖会污染静态像素。应以 valid 与 hit 同时成立作为覆盖条件。
4. **S2 的断流口径不是恒定自然时钟延迟**：实际 S2 RTL 使用 `en=in_valid|flush_active`，无效且非 flush 时流水保持，pixel_valid 拉低。其 behavior_spec 的 647 拍是连续流口径。W1 要求自然时钟固定 647 拍时，不能同时承诺任意断流下与未修改 S2 自动同拍；连续流合体与断流独立验证需明确区分。
5. **仿真纪律冲突**：START_PROMPT 规定通用纪律以 TASK_KICKOFF 为准；该文件 §3 写“仿真只有两个触发场景（除此之外一律不跑）”，而本任务 P0/P1/P4 计划要求先跑独立仿真，且禁止主线集成。需要给此独立任务明确离线仿真例外。
6. **签发入口缺失**：START_PROMPT 的 `../../TASK_KICKOFF.md` 在当前交接目录无法解析；实际纪律文件在项目的 `iccoder_workspace/TASK_KICKOFF.md`。任务内无可执行 `sim/run.sh` 或签发 TD Tcl。
7. **黄金覆盖尚不完整**：状态生成器只提供六个默认场景，没有参数化配置入口，尚不能覆盖合同中的 cfg_boundary、tick_overrun、reset_reentry 等完整矩阵。不得用现有 1800 帧的黄金审计代替这些 RTL 场景。

## 本轮新增产物与复现

- `sim/audit_startup.cjs`：黄金/契约自检和容量候选分析。
- `sim/startup_audit/audit_result.json`：机器可读证据及 SHA256。
- `sim/startup_audit/{nonuniform_luma,outside_before_dilation,all_empty}/input/`：固定 T1/T2/P 快照。
- 各夹具 `golden/`：原生成器输出的完整 640×480 像素文件和行区段。
- `nonuniform_luma/candidate_compact_spans.json`：待签发的紧凑区段候选，独立还原至光平面检查。

在任务根执行：

```powershell
node "sim/audit_startup.cjs"
exit $LASTEXITCODE
```

当前预期退出码为 2，表示已确认存在契约阻塞。断言异常的退出码为 1；不能把退出码 2 当作 RTL FAIL 或审计 PASS。脚本不执行 HDL 仿真，也不生成 sim_result.json，以免与 DUT 结果混淆。

## 工程边界

本轮只新增任务内审计脚本、夹具和交付目录文档。没有改写 `doc/brief`、既有 `reference`、prototype、spec、task_045 或主线，没有执行 Git 操作，没有创建 FINAL_ACCEPTANCE.md。

审计脚本复用签发函数原文，以独立解码和不变量检查为判据，避免复制权威打包逻辑（DRY）；状态黄金、像素黄金与候选存储验证分开承担职责（SRP）。候选存储只针对已复现的容量与亮度冲突，不添加任务范围之外的功能（KISS/YAGNI）。
