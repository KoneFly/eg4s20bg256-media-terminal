# M4 连续频谱脊线行为规格

## 插值

有效x区64..575。`u=x-64; band=u[8:6]; frac=u[5:0]`。选e0与e1（band7时e1=e0），均先按active_shift右移。`diff=$signed({1'b0,e1})-$signed({1'b0,e0})`；`prod=diff*$signed({1'b0,frac})`；`height=$signed({1'b0,e0})+(prod>>>6)`。中间位宽至少diff 9位、prod 15位、sum 10位有符号。wave_y=400-height。

## 层级

height=0时不画波形。优先级：主脊线`abs(y-wave_y)≤1`亮色；mode≥1的≤4核心色、≤8近光；mode≥3的wave_y+16±1近光、wave_y+32±1远光；mode≥2点阵；y420/x48..591地平线；背景。

点阵仅当`x[2:0]<2 && y[2:0]<2`。hash=`x[4:0]^y[4:0]^phase[4:0]^{band,2'b0}`。下方云：`y>wave_y+8 && y<420`，density=max(0,(height>>5)-((y-wave_y)>>6))；hash<density时，深度<64用近光，否则远光。上方云：wave_y-32≤y<wave_y-8且hash<(height>>6)，用近光。

主题色表与Task025一致；亮色=core|39E7，近/远光分通道右移1/2位。非法theme回退0。背景0022/0028/0841，地平线08A5/10AA/2126。

## 状态、资源和时序

复位/坐标/控制语义按INTERFACE_SPEC。目标≤1000 LUT/180 REG/1 DSP/0 ERAM，25.2MHz 0违例。禁止帧缓存、浮点、任意除法、整体RGB565右移和未经批准的流水延迟。
