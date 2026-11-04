# 八路包络内部接口 v0.1

候选接口，仅在新模块内使用；不修改主系统INTERFACE_CONTRACT或M1接口。中间检验通过后冻结。

## Module Declaration

```verilog
module energy_envelope (
    input wire clk,
    input wire rst_n,
    input wire frame_tick,
    input wire hold,
    input wire bypass,
    input wire [1:0] attack_shift,
    input wire [1:0] release_shift,
    input wire [63:0] energy_in,
    output wire [63:0] envelope_out
);
endmodule
```

端口名称、方向、位宽和有效电平是冻结契约，不得修改或新增端口。

clk=25.2MHz。rst_n异步低有效、内部2FF同步释放；输出清0，在功能复位释放前忽略tick。所有输入同步到clk，energy_in是原子8路向量，lane i占[8*i+7:8*i]。不承担CDC；上游多位数据必须用握手/FIFO。

frame_tick为高有效单周期事件，每帧最多一次，由上游在V-Blank产生。本模块对每个采样到高电平的上升沿更新一次，不做边沿检测；连续高两拍定义为两次更新，真实集成应检查其违反每帧单tick前提。

有效tick沿同时采样energy_in、attack_shift、release_shift、hold、bypass，用旧输出算新输出；NBA后新输出稳定，无tick时保持。优先级复位>无tick保持>hold>bypass>正常计算。无tick期间输入或参数变化不得影响输出。

## 参数与更新

attack/release可取0—3，均为运行时输入，不写死parameter；推荐上游复位寄存器默认1/3，hold/bypass默认0。模块本身没有这些输入的默认值。配置与tick同沿时按该沿已满足建立时间的输入采样，不另延后一帧。

## 已知的接口限制

无valid/ready/错误输出；完整更新只依赖tick。M1同沿采样旧envelope_out，故有一帧接入延迟，复位后首帧黑色；不得私改M1消除该延迟。hold不自动连接M1 KEY1；KEY3及sw高位继续保留。物理调参映射属于后续集成，当前不声明已完成。
