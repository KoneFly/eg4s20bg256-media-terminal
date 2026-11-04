# M4 连续频谱脊线接口 v0.1

## Module Declaration

```verilog
module spectral_ridge_renderer (
    input wire clk, input wire rst_n,
    input wire vsync, input wire hsync, input wire de,
    input wire [7:0] band0_energy, input wire [7:0] band1_energy,
    input wire [7:0] band2_energy, input wire [7:0] band3_energy,
    input wire [7:0] band4_energy, input wire [7:0] band5_energy,
    input wire [7:0] band6_energy, input wire [7:0] band7_energy,
    input wire [3:0] key_pulse, input wire [3:0] sw_level,
    output wire [15:0] pixel_rgb565, output wire pixel_valid
);
endmodule
```

端口名称、方向、位宽和有效电平冻结，与M1/M3端口形状同构。clk=25.2MHz；rst_n异步低有效、内部同步释放；HS/VS低有效。输入已同域，跨域由上游负责。

## 时序与坐标

采用Task020/025集成相位：VS低清x/y，DE低清x并在前一拍DE高时增y，DE高沿推进x；与寄存器时序源直连后下降沿观察x=0..639。输出0拍组合；正常有效帧pixel_valid=de&&vsync，消隐/未锁帧pixel=0，越界不回绕。

## 帧提交与控制

frame_commit=VS 1→0。复位frame_phase=511，首次有效帧phase0。提交沿锁存8路能量、theme、mode、shift并使phase+1；整帧稳定。

- KEY0循环theme 0/1/2；KEY1冻结能量快照；KEY2最高优先恢复theme0/freeze0/mode2；KEY3循环mode 0/1/2/3。
- sw[1:0]为能量右移；sw[3:2]保留。
- 按键与提交同沿时提交旧pending，新事件下一帧生效；KEY0/1/3可同拍。

## 插值和像素

x=64..575按64像素分段；band7末段保持e7。定点有符号插值、脊线/辉光/点阵/回声的精确定义见behavior_spec。静音只输出背景和地平线。

## 已知限制

插值允许使用1个DSP；若TD未映射DSP或0拍不收敛，执行方先报告，不得改为多拍后隐式错开015/016。模块不含024/014/AXIS/HDMI；真实音频两帧延迟由集成任务验证。模式3是2D偏移回声，不宣称真实3D投影。
