# pcb_dynamic_layer V2 检查报告

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 结论：本轮两模块独立测量交付完成；资源门禁及部分时序要求失败，功能全矩阵与板级验收未完成。

| 检查 | 状态 | 当前 V2 证据与边界 |
|---|---|---|
| 无粒子配置档与原模型 T1/T2 非干扰比较 | PASS | 默认 2400 帧，sim/vectors/v2/w2/manifest.json |
| W2 默认真实 T1/T2 写口逐字对拍 | PASS | 8×300 帧，sim/sim_result_v2.json |
| 接受后现场频谱扰动、完整写序、单次 commit/done、2FF ack | PASS | tb/tb_w2.cpp 与 sim/logs/v2 场景日志 |
| busy/未 ack 的额外 tick | PASS | tick_overrun：300 帧 |
| 更新中/T2 序列化中复位后重入 | PASS | reset_reentry：300 帧 |
| W1/W2 Verilator lint | PASS | Wall，仅保留 BLKSEQ 风格例外；位宽告警未屏蔽 |
| W1 完整帧 hit/RGB565/alpha | PASS | 8×640×480，sim/w1_result_v2.json |
| 自然时钟 D=647、SOF/EOL、气泡、完成快照间切换 | PASS（已测范围） | TB 在行池完整发布后开始有效帧 |
| W1 36000 拍构建期限 | FAIL | bar_alternating 超限；与像素 PASS 分开登记 |
| 正常 W1 用例 overflow | PASS | 八个实际用例均为零；不等于故意溢出测试 |
| GROW_CAP 右移变异 | KILLED | sim/mutation_result_v2.json，编译成功后 TB 抓到数据失配 |
| 保留配置最小/最大/越界与帧边界完整矩阵 | NOT_RUN | 不从默认参数对拍外推 |
| 故意桶溢出、发布中途切入有效帧 | NOT_RUN | 不宣称原子切帧和所有异常通过 |
| 两模块独立 TD 测量 | COMPLETE | td_run/v2/w2、w1；源码/约束/报告 SHA 绑定 |
| LUT / DSP / 综合级时序 | 见测量报告 | LUT 两项 FAIL；DSP 两项 PASS；W2 setup FAIL |
| TD RAM byte-enable 告警及 gate 分支等价 | OPEN / NOT_RUN | W1 SYN-5011 未消除，只有行为 RAM 仿真 |
| 10 个只读上游文件 | UNCHANGED | sim/td_result_v2.json 独立 SHA 核对 |
| S2 合体、布局布线、上板 | NOT_RUN | 用户本轮指定独立测量范围 |

W2 实际默认/协议对拍合计 3000 帧；W1 共 2,457,600 像素。测试期望来自只读模型和独立几何，不从 RTL 生成；编译 manifest 包含实际使用的核心、RAM、ROM、TB 哈希。变异发生在隔离副本，不改变正式 RTL。

粒子极值、P 字序、槽满替换、历史轨迹/头部/回收用例已退出 V2，不以历史 V1 PASS 填充当前矩阵。所有当前数字、原始报告与告警唯一入口为 `V2_MEASUREMENT_REPORT.md`、`sim/td_result_v2.json`；旧检查报告见 `archive/v1/doc/output/check_report.md`。

没有修改 prototype/spec/task_045 或主线，没有 Git 提交/分支、bit 或 FINAL_ACCEPTANCE.md。功能职责拆分与统一 RAM 词口便于独立复核；本轮失败项照实记录。
