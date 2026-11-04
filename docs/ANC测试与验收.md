# ANC 测试与验收（四麦现行入口 · 2026-10-24）

> **2026-10-25再回填及扩展评估：**主人确认示波器无法导出原始波形，多轮仍观察到约4dB下降；早先个别约5dB保留为历史，不取最高作稳定成绩，锁故障未闭合。主人要求持续低频与宽带/突发噪声均评估，现阶段仅研究，不自动改位；[本板范围与网站工具评估](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/iccoder_workspace/tasks/task_068_audio_demo/doc/output/AUDIO_EXPANSION_AND_SERVERLESS_REVIEW_20261025/REPORT.md)区分声学抵消与采集数字去噪。当前仍未签6dB或稳定通过，不要求重开异常RUN。

> **本轮最新回填：**主人确认RUN时LED1＋2持续亮；电脑播500Hz、手机在同一固定测点/设置下，读数约−18→−23dB，但声音变大、碰线、移动时会转LED1＋4，源音量过高时效果下降。记录为“约5dB读数下降的初步趋势＋RUN故障”，未签≥6dB或稳定通过。先硬静音、暂停源，不再带声反复清故障。详见[后续故障分类](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/iccoder_workspace/tasks/task_068_audio_demo/doc/output/ANC_RUN_FAULT_UPDATE_R04_20261024/REPORT.md)；[前轮核查](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/iccoder_workspace/tasks/task_068_audio_demo/doc/output/ANC_RUN_CRACKLE_REVIEW_20261024/REPORT.md)保留历史。以下通用流程不授权忽略异常继续试。

**主人已确认四只麦到齐、当前杜邦线直连，手边为普通手持示波器和手机。功放接触是否稳定仍待现场确认。** 当前实测组合仍按主R35 / 副R37，具体位与断电后SRAM恢复步骤见下方完整指南；保底R30/R34B不动。

## 现在按哪份操作

**[打开四麦详细测试步骤](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/iccoder_workspace/tasks/task_068_audio_demo/doc/output/ANC_FOUR_MIC_R37_TEST_20261024/ANC_FOUR_MIC_R37_TEST_20261024.md)**。

该指南包含四麦/功放接线、示波器起始设置、进入/校准/运行/退出、A1—B—A2、异常处理、真实bit完整路径/SHA与回填表。普通示波器先查供电、时钟和数据活动；没有I²S解码或独立声学测量时，不把数字SD线FFT当声学降幅。

## 五步带反馈速查

接线/默认远距短检通过后，以下只操作**副板KEY2**：

| 步 | 操作 | 反馈 |
|---|---|---|
| 1 | 500Hz源OFF、功放硬静音；长KEY2≥2.2秒后松开 | LED1单亮=ARM |
| 2 | ARM确认后，先功放5V稳定、再SD选已核3.3V左槽；开固定500Hz取A1 | 注入0；有独立测量才填A1电平 |
| 3 | 关源、安静至少1秒；短KEY2约100～200ms并松开 | LED1+3短暂校准，随后LED1+2=ready/RUN |
| 4 | ready后开同一500Hz源，条件不动，观察并取B | LED1+2保持；量化看独立测点，非MIC234双谱 |
| 5 | 先硬静音、短KEY2回ARM；同条件取A2；结束先静音、关源、长KEY2退出 | A2应回到基线附近；退出后RAW/POST，功放仍静音 |

**啸叫/异常突响/LED4：先硬静音、保存四灯与时刻、停止本轮；不在故障位反复复位/抬GAIN，按完整指南只副回R34B。** 主板暂停与音量不能急停副板功放。

## 四麦连接与口径

MIC1=J1-5/H13误差输入；MIC2=J1-7/J14，MIC3=J1-9/K12，MIC4=J1-13/M14保留采集均值。四只VDD=3.3V、L/R=GND；SCK=J1-1/D14，WS=J1-3/G12，四路SD分开。

功放DIN仍J1-21/G16；默认输出MIC234 RAW/POST，TF音乐从HDMI出声。SD_MODE接GND是关断，不能称RAW。**ARM灯不能单独证明MIC1正常，LED4不能唯一归因为没听到探针；校准探针很轻，未听到“嘀”也不单独判坏。**

只有一部手机时先用它作声源做功能筛查；正式dB需另一个独立声源/测量通道，并固定增益、排除AGC/降噪/AEC。没有量化条件时记待测，不能写ANC已达6dB。

## 历史合并稿

原合并稿含三麦临时接法、旧主副版本，以及功放音乐、SD/GAIN和故障唯一归因等过期/错误描述，已从现行操作入口移出。原文逐字节保留在[本轮输入副本](D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/iccoder_workspace/tasks/task_068_audio_demo/components/anc_four_mic_test_20261024/legacy_input/ANC_MERGED_BEFORE_20261024.md)，更早两篇原始稿仍在`docs/_archive_20261023/merged_sources/`；没有删除历史或改动原封存。

详细测试准备后已有约4dB趋势与故障回填，尚无正式验收通过；不改RTL、不出新bit、不写Flash。详细步骤与源证据优先于旧五步稿的技术判断，后续扩展研究也不等于已实现。
