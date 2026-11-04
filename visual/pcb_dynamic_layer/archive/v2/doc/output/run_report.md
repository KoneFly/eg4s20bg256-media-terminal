# pcb_dynamic_layer V2 实际运行记录

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 状态：独立仿真与 TD 已执行、归档完成；实际失败门禁见 V2_MEASUREMENT_REPORT.md。

## 黄金与仿真

任务根为 `D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/pcb_dynamic_layer`。在此根目录生成当前黄金：

```powershell
node "sim/gen_w2_tb_vectors.cjs"
node "sim/gen_w1_tb_vectors.cjs"
```

输出分别在 `sim/vectors/v2/w2/`、`sim/vectors/v2/w1/`，配置档为 no_particles_v2。W2 生成器另外执行原模型与无粒子模型的 2400 帧 T1/T2 非干扰比较。V1 粒子资料保留作历史复现，不进入本轮。

后端为 WSL Ubuntu Verilator 5.032。实际在任务对应 WSL 根目录执行：

```bash
PROFILE=full bash "sim/run.sh"
bash "sim/run_w1.sh"
bash "sim/run_mutation.sh"
```

三项最终脚本均正常结束。W2 full 指当前十组默认/协议用例，共 3000 帧；W1 为八个完整输入帧，共 2,457,600 像素。W1 像素测试允许等待构建完成，构建拍数由 TB 另报，故本轮脚本退出 0 **不等于消隐期限 PASS**。W2 配置边界与 W1 发布中途切帧未执行。

构建隔离目录为 `/tmp/pcb_dynamic_layer_w2_v2_build`、`/tmp/pcb_dynamic_layer_w1_v2_build` 和变异目录。每次 lint/编译前由 stamp_build.py 将实际拷贝输入的 SHA 写回持久目录，避免临时目录消失造成来源不明。结构化收集器只收集本次实际指定用例，不从旧日志补 PASS；当前结果与当前源码 SHA 再校验。

两份 lint 使用 `--Wall -Wno-BLKSEQ`，位宽告警未关闭。原始 lint、编译、用例与 mutation 日志均在 `sim/logs/v2/`。结果为 `sim/sim_result_v2.json`、`sim/w1_result_v2.json`。

变异仅在隔离副本把 GROW_CAP 的 `>>>8` 改为 `>>>7`。mutant 编译成功，正常运行后在零起始 frame=25、cycle=381108，T1 addr=0/lane=0 被 TB 检出 expected=3489660932、actual=3489660936，退出 1，记 KILLED。正式 RTL 未改。

## 独立 TD

最终 TD 工程各自固定在 `td_run/v2/w2/` 和 `td_run/v2/w1/`，分别作为工作目录、**顺序执行**，避免共享自动中间产物。PowerShell 复现方式：

```powershell
Push-Location -LiteralPath "td_run/v2/w2"
try { & "D:/AnLu/bin/td_commands_prompt.exe" "run.tcl" *> "run.log" }
finally { Pop-Location }
Push-Location -LiteralPath "td_run/v2/w1"
try { & "D:/AnLu/bin/td_commands_prompt.exe" "run.tcl" *> "run.log" }
finally { Pop-Location }
```

两个最终进程退出 0，日志完整出现 V2_TD_COMPLETE 且没有 ERROR。不能只凭 TD 退出码宣称执行成功；前期错误的报告命令也曾退出 0，当前最终 Tcl 使用 report_timing_summary，最终日志不含该错误。临时共用工程和早期推断 RAM 的中间结果不作最终交付依据。

各 Tcl 读取各自当前核心/RAM/ROM 归档，依次 optimize_rtl、read_sdc、optimize_gate、update_timing、report_area、report_timing_summary、report_qor。没有 layout、place、route 或 bit 生成。SDK RAM 只使用公开原语接口，Verilator 使用本包行为 RAM，不复制厂商模型。

50MHz/25.2MHz 时钟、输入/输出 delay 和 uncertainty 全部保存在各自 clock.sdc。false path 仅覆盖外部异步 rst_n 和接收侧 toggle 入口，同步器之后仍计时。时序等级为 Synthesized，不能当作 routed 或板级证据。

## 来源绑定与归档

只对已经存在的报告重新归档：

```powershell
node "sim/archive_v2_result.cjs"
```

脚本检查 V2 完成标记、零 ERROR、正式与归档源码、实际仿真编译输入、黄金文件及 10 个受保护上游 SHA，再生成 `sim/td_result_v2.json` 与两份 TD source_manifest.json。脚本保留实际预算/时序 FAIL，不生成验收文件。

源码、验证脚本、黄金、日志各自承担明确职责；统一归档入口避免重复人工数字。当前数字、风险和未执行项以 `V2_MEASUREMENT_REPORT.md` 为准。V1 运行记录保留在 `archive/v1/doc/output/run_report.md`，V1 结果不替代本轮。
