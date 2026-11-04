# pcb_dynamic_layer W2 实际运行记录

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 当前范围：W2 多周期版；W1 已归档出列。

工具：WSL Ubuntu Verilator 5.032、Tang Dynasty V6.2.168116。最终数字及边界见 W2_MULTICYCLE_REPORT.md。

## 基线与验证

在任务根 D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/pcb_dynamic_layer 执行。原 sim/vectors/v2/w2 基线直接复用，并与 V2 归档逐个 SHA 比较；本轮没有重写基线。

生成实现 ROM 及配置补充：

```powershell
node "sim/gen_roms.cjs"
node "sim/gen_cfg_tb_vectors.cjs"
```

前者只产 W2 ROM，后者从同一原模型的隔离 VM 产七组补充向量，不读取 RTL 或改变冻结配置档。参数名位置唯一匹配校验，layout 克隆隔离，补充 manifest 绑定原模型/配置档/打包器/生成器及全部向量 SHA。

实际在对应 WSL 任务根执行：

```bash
PROFILE=full bash "sim/run.sh"
bash "sim/run_cfg.sh"
bash "sim/run_mutation.sh"
```

最终三项均退出 0。full 为原十组默认/协议共 3000 帧；cfg 另七组共 2100 帧。mutation 成功编译、被 TB 数据失配杀死（mutant 退出 1，验证脚本正常退出 0）。配置 full per-parameter 矩阵未执行，不能从补充组合用例外推。

临时构建目录分别为 /tmp/pcb_dynamic_layer_w2_mc_build、w2_cfg_mc_build、w2_mc_mutation。编译前 stamp_build.py 持久记录实际输入副本 SHA；结果收集器核对当前文件，不从旧日志填 PASS。日志在 sim/logs/w2_mc，结果为 sim_result_mc.json、cfg_result_mc.json、mutation_result_mc.json。

lint 使用 --Wall -Wno-BLKSEQ，保留原风格例外，位宽及实质告警未关闭。正式 W2 端口未改；TB 的配置驱动仅通过 cfg_wr 正式口，原黄金和原协议判据仍保留。

## 独立 TD

每一轮冻结源码到独立目录，拒绝覆盖，原 V2 clock.sdc 逐字复制：

```powershell
& "./sim/prepare_td_w2.ps1" -Revision "trial4"
Push-Location -LiteralPath "td_run/w2_mc/trial4"
try { & "D:/AnLu/bin/td_commands_prompt.exe" "run.tcl" *> "run.log" }
finally { Pop-Location }
```

该目录已完成且用于交付，复现创建阶段需使用新的修订名，不能覆盖 trial4。实际四轮均单独顺序运行；trial4 进程退出 0，完整标记 W2_MC_TD_COMPLETE、零 ERROR。

Tcl 执行 optimize_rtl、read_sdc、optimize_gate、update_timing、report_area、report_timing_summary、report_qor。没有布局布线或 bit。V2 SDC 的 50MHz、I/O delay、uncertainty、异步入口 false path 均未改，未增加多周期 STA 例外。多周期通过真实寄存器和 FSM 实现。

最终 TD 告警为 SYN-5025 及 SYN-6562 各一次，没有 SYN-5011；完整行与风险见测量报告。W2 行为 RAM 验证不视作 TD primitive gate 验证。

## 归档复核

只核对已有产物而不运行 TD：

```powershell
node "sim/archive_mc_result.cjs" "trial4"
```

检查当前源码/实际编译/黄金/原始日志/TD 输入及原 SDC SHA、10 个受保护上游、W1 活动路径出列后，生成 sim/td_result_mc.json 和 trial4/source_manifest.json。硬门禁与 4000 优化目标独立记录。

V2 351 个原文件的复制与校验由 sim/archive_v2.ps1 已实际完成；该脚本拒绝重复覆盖，只作此次归档记录，不需要重跑。V2 运行资料在 archive/v2。未修改上游或主线，未执行 Git 操作、定板或集成。
