# pcb_dynamic_layer 实际运行记录

> 日期：2026-10-04  
> 状态：W2 默认/协议仿真通过；TD 面积失败，后续 W1 暂停。

在任务根目录生成黄金：`node "sim/gen_w2_tb_vectors.cjs"`。期望来源为只读 `prototype/pcb_model.js`，8 场景×300 帧，manifest 记录模型、生成器、打包器与二进制 SHA256。数据是独立模型结果，不读取 DUT。

实际仿真后端为 WSL Ubuntu Verilator 5.032。切换到任务 WSL 路径后执行：

```bash
PROFILE=full bash "sim/run.sh"
bash "sim/run_mutation.sh"
```

两项最终运行均退出 0。run.sh 的 full 仅指当前 W2 场景集合，不表示整个 W1/W2 验收矩阵已完成。支持 PROFILE=quick|full 以及 SCEN_ONLY；必须先生成对应向量。编译隔离目录分别为 `/tmp/pcb_dynamic_layer_w2_build` 与 `/tmp/pcb_dynamic_layer_w2_mutation`，不改变正式 RTL。内部 INIT 用运行时写入，无 HDL initial 清零依赖。

标准场景的最高控制周期：

| 场景 | 对拍帧数 | 最大周期 |
|---|---:|---:|
| boot_silence | 300 | 8274 |
| boot_low / play_low | 各 300 | 9430 |
| play_mid | 300 | 9525 |
| play_high | 300 | 9330 |
| saturate / silence_decay | 各 300 | 22757 |
| impulse_broadcast | 300 | 10549 |
| tick_overrun / reset_reentry | 各 300 | 9430 |

变异只将 GROW_CAP 的算术右移 8 改为 7。mutant 本身成功编译并正常运行；TB 在零起始 frame=25、cycle=181892 捕获 T1 地址 0/lane0 期望 3489660932、实际 3489660936，退出 1。mutation_result 状态为 KILLED，排除了编译失败或 timeout 被误认为杀死。

实际 TD：在任务自己的 td_run 工作目录执行 AnLu `td_commands_prompt.exe "w2_area_rev2.tcl"`，退出码 0。Tcl 读取固定 rev2 源码并运行 optimize_rtl、optimize_gate、report_area；没有 layout/place/route。`#lut=6646`、`#Total_luts=4642`、`#reg=2204`、`#dsp=1`、`#bram9k=26`、`#bram32k=0`。本顶层不包含外部 P 状态表，不能用零个 32K 声称 P bank 已符合物理要求。

宽内部端口直接作为面积顶层导致 #pad=1133 >188，此记录仅用于逻辑面积审计。未产出可烧录工程，Setup/Hold WNS 均为 NOT_RUN，未尝试通过裁掉频谱位或输出位骗取资源通过。

rev2 TD 待处理告警：

- SYN-5011：rev2 RTL 第 62/64 行对应的 ramread3_syn_4 / ramread1_syn_4 推断 RAM 的 bea[0]/beb[0] 未驱动。
- SYN-5025：未驱动引脚/网络按零处理。
- SYN-6562：部分推断 RAM 的初始化值被 eram_init=off 忽略。

RTL 的运行时初始化在 Verilator 中已覆盖；这不能消除 RAM byte-enable 的 gate 语义风险。当前没有 gate 仿真、上板或任务既有 TD 告警基线，不将这些告警称为继承或已验收。

证据：`sim/logs/`、`sim/sim_result.json`、`sim/mutation_result.json`、`sim/td_result.json`、`td_run/rev2/source_manifest.json` 以及对应 TD 原始 area/log。归档脚本 `node "sim/archive_gate_result.cjs"` 将当前 RTL 与实际 area 绑定并核对只读上游；仅用于已存在的 rev2 报告，不会运行 TD。
