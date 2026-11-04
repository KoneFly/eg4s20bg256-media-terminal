# VERIFICATION_CONTRACT — pcb_dynamic_layer W2 多周期版

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 授权依据：用户批准“W1 整体出列 + W2 多周期化重构”。V2 原版与证据见 archive/v2。

no_particles_v2 是冻结黄金基线。不得改模型、packState、刺激或原向量使其匹配 RTL；黄金不从 DUT 生成。W1 的像素/延迟/行桶用例整体出列，不能计入本轮 PASS。particles_v1 只作历史参考。

| 范围 | 原判据与当前要求 |
|---|---|
| W2 状态 | boot_silence、boot_low、play_low、play_mid、play_high、saturate、impulse_broadcast、silence_decay 各 300 帧；正式 T1/T2 写口逐字零失配 |
| W2 协议 | 652 写，完整地址/lane、commit 单次/done 单拍、ack 2FF、接受后频谱扰动、overrun、更新中/T2 发布中复位 |
| 配置 | 默认、范围饱和及帧锁存保持；最小/最大/越界完整参数矩阵未执行项照实 NOT_RUN，新增检查不得替代默认基线 |
| 变异 | 故意算术/字序错误被正常运行的独立 TB 杀死；编译失败/timeout 不算杀死 |
| 门禁 | 独立 TD #lut≤4500，争取≤4000；DSP≤2；50MHz 综合级 Setup/Hold 零违例 |
| 时钟约束 | 与归档 V2 clock.sdc 逐字相同，不增加 multicycle_path/false_path 或降低 uncertainty |
| 更新耗时 | 每场景报告实测最大拍数，≤833333；不能以名义周期换算掩盖时序 FAIL |
| 证据 | 实际编译核心/RAM/ROM/TB、黄金、TD 输入/报告绑定 SHA；10 个受保护上游 SHA 不变 |

原默认 2400 帧模型非干扰检查和二进制 manifest 保留。本轮重用原向量。算术拆步须保留有符号移位、取整、饱和、槽选择及 node/bar/flow/彗星更新顺序。关键帧握手仍只通过正式接口检查，不读写 DUT 内部状态后门。

WSL Ubuntu Verilator 离线例外继续有效，禁止 iverilog。lint --Wall，仅保留 BLKSEQ 临时算术风格例外，不屏蔽位宽或实质性告警。TD 使用公开 RAM primitive 接口；未执行 gate primitive 仿真和配置完整矩阵时必须明确登记。

综合级通过不代表布局布线或板级通过。用户本轮仍禁止定板/集成范围，不生成 bit 或 FINAL_ACCEPTANCE.md。
