# M5 潮汐星流接口 v0.1

## Module Declaration

```verilog
module tidal_particle_renderer (
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

端口名称、方向、位宽和有效电平为冻结候选契约，不得修改或新增端口。与M1/M3/M4渲染端口形状同构；本任务只产出像素/valid，AXIS和RGB888由后级完成。

## 时钟、复位、像素相位

clk为25.2MHz pixel域。rst_n异步低有效、内部2FF同步释放。vsync/hsync低有效，de为有效区。所有输入已同步到pixel域；8路能量同一批原子数据。

复位后先观察VS低再使能像素；正常有效帧`pixel_valid=de&&vsync`，消隐像素/valid均0。x/y按Task020已上板坐标相位计数；与寄存器video_timing_data连接时下降沿应看到x=0..639。x饱和640、y饱和480，越界有效区输出背景色但valid仍跟随de，不能回绕。

## 帧更新

frame_commit为VS 1→0采样沿，每帧最多一次。先以旧粒子状态并行更新、年龄到12的粒子失活；随后处理cursor与cursor+1两槽发射，发射覆盖同槽旧状态。LFSR推进两次，cursor加2模16，phase加1模64。能量在该沿锁存并作为此轮发射/环形画面的强度；若冻结则上述状态和能量快照全部保持。参数和粒子整帧稳定。具体公式与像素优先级见doc/spec/behavior_spec.md。

KEY0循环theme0/1/2/0，KEY1切换pending_freeze，KEY2最高优先恢复pending_theme0/pending_freeze0；KEY3忽略保留。sw_level[1:0]在提交沿锁存右移幅度0..3，高两位保留。按键与提交同沿则提交旧pending、下一场生效。

## 已知的接口限制

画面只有8方向定点近似圆环，浏览器64点平滑环仅为创意探索，不是本模块像素黄金。粒子上限16、每场最多新发射2个，静音目标经014包络衰减后才停止发射；已有粒子最长再持续12个场更新。模块无ready、帧缓存、字幕、转场或真实音频接收功能。036稳定及M4上板前只进行模块级验证。
