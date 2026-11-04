# VERIFICATION_CONTRACT — pcb_dynamic_layer V2

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 授权依据：用户本轮批准的“规格变更 V2 + 重构授权”。V1 历史资料见 archive/v1。

期望值必须来自只读模型或独立几何脚本，不读取 RTL 输出生成黄金。新增 no_particles_v2 为当前配置档；particles_v1 仅用于历史复现。粒子相关极值、P 字序、粒子槽满替换、历史轨迹/头部/回收用例退出 V2 矩阵。保留以下判据：

| 范围 | 当前独立矩阵与判据 |
|---|---|
| W2 状态 | boot_silence、boot_low、play_low、play_mid、play_high、saturate、impulse_broadcast、silence_decay 各 300 帧；逐写口 T1/T2 数据零失配 |
| W2 协议 | 512+140=652 写，地址/lane/提交单次/done 单拍、ack 2FF、接受后频谱扰动、overrun、更新中/T2 发布中复位 |
| W2 参数 | 保留参数最小/最大/越界及帧边界应用；未执行部分必须标为 NOT_RUN |
| W1 像素 | 8 组 640×480 完整帧：空、阶梯、三角、饱和、交替、随机、alpha=0/17；hit/RGB565/alpha 零失配 |
| W1 时序语义 | 自然时钟 D=647，断流与 SOF/EOL 精确延迟，不增补无来源像素；完整快照之间切换 |
| W1 构建 | 只能在无效像素期构建，构建后完整帧与黄金等价；36000 拍消隐期限单独判定，不能被像素 PASS 掩盖 |
| 变异 | 至少故意算术/字序错误被独立 TB 杀死，不把编译失败/timeout 算作杀死 |
| TD | 两模块分别报告 #lut、#Total_luts、REG、DSP、ERAM9K/32K、Setup/Hold WNS、覆盖率与告警；标明 Synthesized/Routed 级别 |

V2 模型配置档只移除已批准粒子调用与 LFSR 触发，保存原始模型 SHA。默认 2400 帧另与未修改模型的 T1/T2 比较，证明删除对剩余状态无影响。W1 黄金跳过粒子、保留原柱顶公式、裁剪/膨胀/调色/打包回环。每个实际编译输入、黄金及 TD 原始产物绑定 SHA。

沿用已批准的 WSL Ubuntu Verilator 离线例外，禁止 iverilog；lint --Wall，仅保留 BLKSEQ 局部算术风格例外，不屏蔽位宽告警。不修改上游或主线，不以综合级时序/离线 PASS 宣称板级通过。
