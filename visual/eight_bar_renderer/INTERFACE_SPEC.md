# 八柱渲染器接口 v0.1

状态：中间检验候选。批准后冻结；不修改工作区主接口合同。

## Module Declaration

```verilog
module eight_bar_renderer (
    input wire clk,
    input wire rst_n,
    input wire vsync,
    input wire hsync,
    input wire de,
    input wire [7:0] band0_energy,
    input wire [7:0] band1_energy,
    input wire [7:0] band2_energy,
    input wire [7:0] band3_energy,
    input wire [7:0] band4_energy,
    input wire [7:0] band5_energy,
    input wire [7:0] band6_energy,
    input wire [7:0] band7_energy,
    input wire [3:0] key_pulse,
    input wire [3:0] sw_level,
    output wire [15:0] pixel_rgb565,
    output wire pixel_valid
);
endmodule
```

端口名称、方向、位宽和有效电平是冻结契约，不得修改或新增端口。

## 时钟、复位与输入前提

- `clk`=25.2MHz。所有输入必须已同步到本域；8路能量作为同一批数据，满足场提交边沿的建立/保持时间。跨域多位总线由上游握手或 FIFO 交付，不能逐位2FF。
- `rst_n` 异步拉低；内部2FF同步释放（释放至少经过两次有效上升沿，功能逻辑再按同步复位状态开始工作）。复位期间输出零、valid=0。
- `hsync/vsync` 低有效。正常输入640有效像素/行、480有效行/帧；每行DE单个连续高区间，DE低区间至少一拍；VS低时DE必须低。参考总时序800×525。
- 按键高有效一拍、已消抖；`sw_level` 为同步稳定电平。输入事件以 `clk` 上升沿采样。

## 像素与坐标的拍级约定

延迟固定为 **0拍组合输出**：在某上升沿采样的输出对应同一沿采样的 `de` 和当前坐标，无输出寄存器。上游时序在上一沿之后更新，输出必须在下一采样沿前稳定。

TB推荐采用明确顺序：下降沿驱动下一像素的输入，等待组合逻辑稳定，在下一上升沿之前检查该像素输出，然后由下一上升沿推进DUT状态。若采用上升沿监视器，必须获取该沿NBA更新前的输入与输出；不能在上升沿NBA后把已递增的x输出当作刚被接收的像素。固定时序源若在上升沿更新HS/VS/DE，可在随后的下降沿检查当前周期输出，以同一周期的外部坐标为期望。两种驱动方式不要混用采样基准。

内部 x 计数表示当前将被采样的有效像素位置：复位/任一DE低采样沿置0；DE高采样后递增。10位饱和到640，超过639禁止着色，禁止回绕成第二根起始柱。

内部 y 表示当前有效行：复位/VS低采样沿置0；检测上一拍DE=1且当前DE=0时递增（在该行最后一个有效像素被采样后）。10位饱和到480，超出479禁止着色。行消隐不等于场提交。HS输入保留用于主接口兼容及TB协议检查；本版坐标采用DE边沿和VS清零，不按HS脉冲计行。

复位后必须先采到VS低，才置 `frame_seen`。此前valid=0，避免从帧中间复位后把残帧当完整帧。正常锁定后 `pixel_valid=de && vsync`；异常过长行/多行仍跟随有效标记，但像素黑色。VS低或复位/未同步时强制valid=0、像素=0。DE低时像素=0。设计不负责检测所有坏时序，也没有错误状态输出。

## 场提交与参数事件

`frame_commit` 定义为内部复位释放后检测到 `vsync` 从1变0的采样沿；VS历史寄存器复位为1，因此启动时VS已低也能产生一次提交。

每个提交沿同时锁存8路能量和配置，整个有效帧内保持稳定。

| 状态 | 位宽/默认值 | 行为 |
|---|---|---|
| pending_palette | 2/0 | KEY0递增：0→1→2→0 |
| pending_freeze | 1/0 | KEY1翻转 |
| active_palette | 2/0 | 提交沿采样旧pending_palette |
| active_shift | 2/0 | 提交沿采样sw_level[1:0]，范围0—3 |
| energy_snapshot[0..7] | 每项8/0 | 旧pending_freeze=0时提交沿锁存能量；为1时保持 |

KEY2最高优先级：将pending_palette/pending_freeze恢复0；不改开关幅度，也不立即清空画面。KEY0与KEY1同时到达且KEY2=0则分别执行。KEY3、sw_level[3:2]保留且忽略。按键可在有效区修改pending，active仅在场提交沿改变。按键与场提交同沿时提交旧pending，新按键在下一次提交生效；解冻后第一次允许提交时采集当前输入。复位清空pending、active、快照和坐标。

这些是固定候选行为，不留给实现方自行解释；批准前如需变更由规格方统一修订。

## 已知的接口限制

1. 无ready端口、无法停顿。主线须证明HDMI有效期连续消费，或独立提供已验证的缓冲/错误恢复方案。不得因ready低改变视觉计数或吞掉像素。
2. 输出RGB565，Task 011 的 `axis_s_data[23:0]` 是RGB888。后续适配建议 R8={R5,R5[4:2]}、G8={G6,G6[5:4]}、B8={B5,B5[4:2]}，主线批准后实施。
3. `video_source_b_fixed` 没有外部像素输入。本任务不改其端口、不生成AXIS；新适配模块需另立项。
4. 没有LED/数码管参数回读端口。原型显示数值只服务调试，硬件首版靠画面检查配色/冻结/幅度；如要回读须重新对齐接口。
5. 本版仅支持上述DE连续且分行、VS低有效的输入。异常帧被VS重新定位；对任意时序损坏不承诺完整自动诊断。
