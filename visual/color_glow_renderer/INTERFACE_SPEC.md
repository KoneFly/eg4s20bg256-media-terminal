# M3 色光渲染器接口 v0.1

## Module Declaration

```verilog
module color_glow_renderer (
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

端口名称、方向、位宽和有效电平是冻结契约，不得修改或新增端口。端口形状与M1同构，模块名不同；后续集成通过替换实例选择内容源。

## 时钟、复位与坐标相位

clk=25.2MHz；rst_n异步拉低、内部2FF同步释放。HS/VS低有效，DE为有效区。所有能量、按键、拨码已经同步到本域；8路能量为同一批原子数据。跨域交付由上游负责。

复位后先观察到VS低再使能输出；此前pixel_valid=0、pixel=0。正常有效帧pixel_valid=de&&vsync，消隐pixel=0。坐标使用Task020集成修订语义：VS低清零x/y，DE低清x并在前一拍DE高时递增y，DE高采样沿推进x且饱和到640。与Task020寄存器时序源直连后，在下降沿观察当前组合输出，x必须依次为0..639。y饱和到480；越界有效时隙输出0但valid仍跟随DE。

输出为0拍组合逻辑。TB对组合输出在下降沿/下一采样沿之前检查，不能在上升沿NBA后把已推进状态误作刚采样像素。

## 场提交与控制

VS 1→0采样沿为frame_commit，同时锁存8路能量、active_theme、active_glow、active_shift，并使9位frame_phase加1（模512）。复位frame_phase=511，使首次提交后的有效帧phase=0；整帧保持，因此纹理亮点不会在帧内跳动。pending初值：theme=0、freeze=0、glow=2；active同值。key_pulse已经是单拍事件，模块直接采样，不再二次边沿检测。

- KEY0：pending_theme 0→1→2→0。
- KEY1：pending_freeze翻转；冻结时能量快照保持，主题/光晕/幅度仍可提交。
- KEY2：最高优先级，把pending_theme/freeze/glow恢复0/0/2。
- KEY3：pending_glow按2位自然递增，0→1→2→3→0；复位初值2，因此首次KEY3得到3。
- sw_level[1:0]：提交为active_shift；sw_level[3:2]保留忽略。

按键与frame_commit同沿时提交旧pending，按键结果下一次提交生效。KEY0/1/3可同拍分别生效；KEY2同拍覆盖三者。所有active状态整帧保持。

## 像素几何与颜色

完整公式、色表和优先级见 `doc/spec/behavior_spec.md`。必须满足：8槽、核心40像素、6×6单元/2像素栅格间隔、四级垂直量化渐变、随frame_phase移动的无状态亮点、近/远光各3像素、最大顶部光晕7像素、柱底419、地平线420；能量0无光晕。

## 已知的接口限制

模块不含ready/AXIS/RGB888；复用015/016完成后续适配。板级Task020目前key/sw固定0；默认theme0/glow2保证可见。B2/C1物理按键与播放主控存在共享决策，集成任务必须明确映射。M3替换M1后仍需集成级逐拍相位回归，模块TB通过不能代替该证据。
