# W2 当前只读参考与口径

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 当前范围：W2 多周期版；W1 已归档出列。

当前授权范围与门禁以 doc/brief 四份文档为准。V1/V2 历史摘录保留在 archive/v1、archive/v2，本轮不修改任何受保护上游。

期望来源为只读 prototype/pcb_model.js，几何为 pcb_layout.js；正式 T1/T2 布局沿用 task_045 的 packState。reference/profiles.cjs 的 no_particles_v2 适配只删除已批准外侧粒子调用，文件与原基线保持 SHA 不变。原模型非干扰 2400 帧和基线 manifest 保留为 V2 历史生成证据；本轮重新检查实际 DUT 正式写口。

保留 T1 128×128bit（70 条有效走线、其余地址写零）与 T2 0..139 的字段。core=256 按字节掩码写为零，彗星字按 amp|(dir&3)<<8|(pos&0x3ff)<<10，peak=0 为走线脉冲空槽判据。128 音柱 H/Peak、四个彗星、节点/元件状态均保留。当前黄金、生成器/打包器/模型 SHA 由 sim/archive_mc_result.cjs 与 V2 归档复核。

配置补充只在隔离 VM 中绑定同一模型的八个参数；克隆 layout，避免模型派生几何相互污染。七组补充向量不替代或重写默认 no_particles_v2 基线，不从 RTL 输出生成期望。原始上游文件 SHA 始终独立核对。

W1 的柱顶几何、行桶、像素延迟及黄金已出列；原 RTL 与证据保留在 V2 归档，解析式绘制为二期候选。当前包仅 W2，不修改 S2、主线或板级落点。

