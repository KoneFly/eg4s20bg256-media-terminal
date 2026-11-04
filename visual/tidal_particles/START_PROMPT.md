# M5 潮汐星流启动说明

待中间检验通过、正式立项并由用户启动实现方后使用。

## 必读

1. `../../TASK_KICKOFF.md`
2. 本目录 TASK_BRIEF.md、INTERFACE_SPEC.md、VERIFICATION_CONTRACT.md、doc/spec/behavior_spec.md、reference两文件

第一项按正式tasks位置解析。通用L0/L1/L2、bit、代码合规与清理纪律由TASK_KICKOFF统一规定，本文件仅列本任务细节。

## 模型选择建议

**标准档**适合接口已冻结的单模块RTL与TB；若0拍环/粒子并行命中出现TD负裕量，切换强推理档做路径定位与方案证伪，不扩大改动到已验收上游。

## 上游依赖

Task030 `spectral_ridge_renderer.v`提供同构内容端口；Task014 `envelope_out[63:0]`按lane0低8位；Task020提供上板坐标相位、Task036提供主线资源/时序基线。指纹在reference/UPSTREAM_FACTS.md。以正式源码为准，不凭示例猜端口。

## 分阶段执行

固定手算向量→状态机RTL→像素逻辑→L0首两场与八方向→L1全部14场→首次变异→TD模块资源/时序→交接。P01/P02/P06属于L0，估算<30秒；其余P03–P14属于L1，估算<5分钟；64/128场与全帧像素属于L2，先评估Verilator后后台运行。按Brief可观测性章节在handoff_packet交最小ChipWatcher探针和A/B预期映射。

## 不要做的事

不得把浏览器64段平滑环当作本任务黄金；不得用当前036 P1面积推断将来P3集成PASS；不得把下落音块和伪3D地形偷偷加入本任务RTL；不得因浏览器截图可见而忽略八方向/寿命/种子锚。其他通用红线见TASK_KICKOFF。
