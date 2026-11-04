# M6-FDI 候选位上板操作步骤（bit 6B810152）

> 日期：2026-10-05 ｜ 编写：浮浮酱 ｜ 对象位：`M6_FDI_R2_20261005_6B810152.bit`
> 判据表原件：`ROUND2_BOARD_RECORD.md`（本手册为其操作展开）｜ 卡契约：`CONTROLLED_TF_CARD_V2.md`

---

## 0. 实物清单（先备齐）

| # | 用途 | 文件（完整路径） | 指纹 |
|---|---|---|---|
| 1 | **主板位**（本次验收对象） | `visual_workspace\rtl_handoff\m6_full_display_integration\deliverables\M6_FDI_R2_20261005_6B810152.bit` | SHA256 `6b810152e09eef36138e0ce8979712609a0828b18bf93de2b623fba79929b030`（636626 字节） |
| 2 | **副板位**（已验收，保持不动） | `iccoder_workspace\tasks\task_052_ethernet_pcm_link\td_run\eth_udp_fft_slave_top.bit` | SHA256 前 16 `7175ECC336974A56` |
| 3 | **卡镜像**（现成，含 4 首短曲） | `visual_workspace\rtl_handoff\m6_full_display_integration\sim\round2_card\label_pcm_short_real.img` | SHA256 `db41b9c551ccde1c0ecdad878e997357ff9443f56ff095096e69407933f3a5f0`（128 MiB） |
| 4 | 回退位（万一异常） | `iccoder_workspace\tasks\task_052_ethernet_pcm_link\td_run\eth_udp_m6_master_top.bit` | 前 16 `75959E68B425DE7A` |

**卡镜像内容**（`label_pcm_short_real.img`）：PCB 标签图（LBA64–1864）+ 四槽受控 PCM（WAV1 10.1s / WAV2 12.2s / WAV3 14.3s / WAV4 16.4s）。
仅想验画面时可用更小的 `sim\round2_card\label_only.img`（只含标签图，无 PCM）。

> ⚠ **本位不含真音频输出**：本 FDI 位只从 TF 读"标签图"；卡上 WAV 是为后续第五步真音频合体预留的。
> 频谱动态由副板 FFT 对主板测试 PCM 流计算后回传驱动；**上板只需要"画面 + 频谱动态"两条判据，不听声**。

---

## 1. 写卡（PC 侧）

### 1.1 准备（先做，别跳）

1. 取一张 **SDHC TF 卡，容量 ≥128 MiB**（镜像固定 128 MiB，更大卡的剩余空间不使用）；
2. **备份卡内原数据**——整盘写入会重写分区表；
3. 插上读卡器，在「此电脑」里记下它出现的**盘符**（如 `E:`）与**容量**；
4. 🔴 **危险确认**：打开「磁盘管理」`Win+R` → `diskmgmt.msc`，核对**容量与盘符**，确认即将写入的是读卡器而**不是硬盘**。**选错盘 = 整块硬盘数据被毁，不可恢复。**

### 1.2 写入镜像（推荐 Win32DiskImager）

下载：Win32DiskImager（SourceForge 官方版），**以管理员身份**运行。操作顺序：

| 步骤 | 操作 |
|---|---|
| 1 | 「Image File」框：点文件夹图标 → 选 `…\m6_full_display_integration\sim\round2_card\label_pcm_short_real.img` |
| 2 | 「Device」下拉框：选中**读卡器那个盘符**（如 `E:\`）——**下拉里显示的只有盘符，别凭字母猜，回头对一次磁盘管理** |
| 3 | 确认 **「Only read/write MBR」复选框为未勾选**（勾上就只写 MBR，等于写坏） |
| 4 | 点 **Write** → 弹窗警告"会覆盖设备数据" → 确认 |
| 5 | 等进度条走完（128 MiB 很快，约 10~60 秒）→ 提示 Write Successful |
| 6 | **若 Windows 弹「需要格式化才能使用」→ 点「取消」**，别点格式化（分区表是受控格式，Windows 认不出属正常） |

> 也可用 **Rufus**（设备选卡 → 映像选 `.img` → **DD 模式**）或 **balenaEtcher**（Flash from file）。
> ❌ 绝不用「复制粘贴文件到卡」的方式；写完**不要**重新分区、不要格式化。

### 1.3 读回校验（重要，不做就无法区分"卡问题"和"位问题"）

**① 读回**
- Win32DiskImager（或同一工具）中，把「Image File」改为一个新文件名，例如 `D:\readback.img`，点 **Read**（注意：Read/Write 共用同一个文件框，别点成 Write！）；
- 读回耗时与卡容量成正比（32 GB 卡约数分钟），耐心等完；
- ⚠ 读回文件通常**比镜像大**（工具读的是整卡），下面第②步会截取前 128 MiB。

> 如果 Win32DiskImager 版本带 **Verify Only** 按钮，可先点它做一次快速比对（其比对长度以镜像为准）。

**② 只取前 128 MiB 并算哈希**（PowerShell 一行一命令即可）：

```powershell
# 截取前 128 MiB
$src = "D:\readback.img"
$dst = "D:\readback_128M.img"
$n   = 134217728
$fs  = [IO.File]::OpenRead($src)
$buf = New-Object byte[] $n
$got = 0
while ($got -lt $n) { $r = $fs.Read($buf, $got, $n - $got); if ($r -le 0) { break }; $got += $r }
$fs.Close()
[IO.File]::WriteAllBytes($dst, $buf)
"read=$got bytes"
```
```powershell
# 算哈希
certutil -hashfile "D:\readback_128M.img" SHA256
```

**③ 判据**：必须等于镜像指纹

```
db41b9c551ccde1c0ecdad878e997357ff9443f56ff095096e69407933f3a5f0
```

**④ 再用工具脚本做结构化校验**（检查标签双 CRC、双 FAT、四槽素材簇链，比哈希更细）：

```powershell
$fdi = "D:\Download\嵌赛fpga_安路\eg4s20bg256\topic1_media_terminal\visual_workspace\rtl_handoff\m6_full_display_integration"
python "$fdi\scripts\make_controlled_card.py" verify "D:\readback_128M.img"
```
（若没装 Python，可跳过本步——哈希一致已经足够。）

**⑤ 安全弹出**读卡器，把卡插入**主板**卡槽。

### 1.4 （可选）自建卡：换自己的素材

素材规格：**无 RIFF 头、16bit 小端、单声道、48000 Hz 裸 PCM**，每槽字节数为**非零偶数且 ≤ 1,920,000（20 秒）**。
参考素材：`iccoder_workspace\tasks\task_052_ethernet_pcm_link\reference\tf_media_20261005\short\WAV1~4.WAV`。

```powershell
$fdi = "D:\Download\嵌赛fpga_安路\eg4s20bg256\topic1_media_terminal\visual_workspace\rtl_handoff\m6_full_display_integration"
python "$fdi\scripts\make_controlled_card.py" build --output "$fdi\m6_card_ready.img" --pcm "D:\pcm\WAV1.WAV" "D:\pcm\WAV2.WAV" "D:\pcm\WAV3.WAV" "D:\pcm\WAV4.WAV"
python "$fdi\scripts\make_controlled_card.py" verify "$fdi\m6_card_ready.img"
```
工具只新建镜像文件，**拒绝覆盖已有输出、拒绝直接写物理设备**（写卡仍需 §1.2 的工具）；产出 `m6_card_ready.img` 与其 `.img.json`（登记素材 SHA）。

---

## 2. 烧录（约 5 分钟）

**2.1 核对 SHA**（烧前必做；Windows 无 sha256sum 时可用 `certutil -hashfile <文件> SHA256`）：
```
certutil -hashfile "D:\...\M6_FDI_R2_20261005_6B810152.bit" SHA256
```
→ 必须为 `6b810152e09eef36138e0ce8979712609a0828b18bf93de2b623fba79929b030`。

**2.2 烧主板**：TD Programmer → 选上述 `.bit` → 烧录到**主板**。
⚠ **主板数码管 P7 仍显示旧位号 05401，无法区分新旧位**——**只能靠 SHA 确认**，别凭 P7 判断烧没烧对。

**2.3 烧副板**：TD Programmer → 选 `eth_udp_fft_slave_top.bit`（7175ECC3）→ 烧到**副板**（若副板已是该位且未动过，可跳过）。

**2.4 插卡**：把写好的 TF 卡插入**主板**卡槽。

---

## 3. 接线与上电

1. **两块板网口直连**（网线对接，不经 PC/交换机）；PC 不参与本次测试；
2. 主板接 HDMI 显示器（**HDMI-B** 口为 M6 输出口）；
3. 上电顺序：先副板、后主板（或同时）——**两板都要上电**，副板不在则无频谱动态。

---

## 4. 上板判据（7 项，逐项填 `ROUND2_BOARD_RECORD.md`）

| # | 观察项 | 期望 |
|---|---|---|
| 1 | 上电 ~3 秒内 | 屏幕出现**完整 PCB 线稿**：外圈大圆 + 128 音柱 + 70 走线 + 元件 + 芯片（QFP/引脚/裸片/片内四块），**无错位、无撕裂、无花屏** |
| 2 | 频谱动态 | 音柱高度起伏 + **柱顶峰值帽** + 走线上的电流亮点/脉冲 + 节点辉光 + 环上彗星 |
| 3 | 底部柱形图 | y≥451 的 **128 路常驻柱**随频谱起伏 |
| 4 | 静音收敛 | 音频静默时：柱归零、粒子/脉冲消失、节点慢释到 0；**线稿仍保持** |
| 5 | 无卡诊断 | 拔掉 TF 卡复位：数码管显示 **`60083`**（=60000+83 无卡），屏幕无标签底图 |
| 6 | 坏卡诊断 | （可选）写一张内容错误的卡：按错误类型见 §5 故障码表 |
| 7 | 连续稳定 | **≥10 分钟**连续播放无黑屏/闪断/花屏；记录时长与现象 |

**建议记录方式**：每项拍 1 张照片或 10 秒视频；第 7 项记起止时刻。

---

## 5. 故障码与处置

数码管显示 `60000 + 故障码`（十进制）：

| 码 | 含义 | 处置 |
|---|---|---|
| **83** | 无卡 / 卡未识别 | 重插卡、确认卡为 SDHC 且已按 §1 写入 |
| **05** | 扇区 CRC16 错 | 卡质量/接触问题 → 重写卡或换卡 |
| **40** | BMP 头错误 | 镜像内容不对 → 重新写卡 |
| **41** | 文件 CRC32 错 | 同上 → 重新写卡并做 §1.3 读回校验 |
| **48** | SDRAM 标签读回 CRC32 错 | 重上电重启；若复现则记录并上报 |

**回退**：若出现黑屏/无信号/花屏等异常 → 退回已验收的 `eth_udp_m6_master_top.bit`（**75959E68B425DE7A**，副板保持 7175ECC3），先恢复"底部 128 柱"保底演示，再把现象回报。

---

## 6. 注意事项（三条）

1. **P7 不能区分新位**——一律以完整 SHA 判定烧录对象；
2. **本位与 052 第五步真音频是两个位**，不要混烧、不要互相回退；本次只验"标签图 + 动态 + 柱"；
3. 卡是**受控格式**（非普通 FAT 拷贝卡）——不能拿日常用的素材卡直接插，必须按 §1 制作。

---

*浮浮酱 2026-10-05 ｜ 关联：`BURN_INDEX.md`（M6-FDI 行）、`docs/DECISION_LOG.md` D-19*
