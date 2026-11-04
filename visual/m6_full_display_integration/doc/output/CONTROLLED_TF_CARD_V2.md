# M6-FDI V2 受控 TF 卡制作契约

2026-10-05。标签与 PCM 共用受控 TF 卡。052 第五步的受控 PCM 使用 FAT32 根目录文件，本轮保留这个契约；标签读取器只访问分区前固定 LBA，不挂载文件系统。Flash 未采用。M6-FDI 仍保持启动包边界：本轮不合入第五步真音频应用层。

| 区域 | 受控格式 |
|---|---|
| LBA0 | MBR，第一个分区类型 0C，起始 LBA2048 |
| LBA64–1864 | 本包固定 PCB.BMP，921654 字节，1801 扇区；末扇区54有效字节及458补零字节 |
| LBA1865–2047 | 保留，不与 PCM 分区相交 |
| LBA2048起 | FAT32，512字节扇区、1扇区/簇、32保留扇区、双 FAT、根簇2 |
| LBA6144 | 根目录首扇区，数据区起点 |
| PCM 根文件 | WAV1.WAV–WAV4.WAV；无 RIFF 头，16bit LE、单声道、48000Hz裸 PCM；每槽非零偶数长度且≤1920000字节/20秒 |

镜像固定128MiB（262144扇区），专用 SDHC 卡需容得下该镜像；较大卡的剩余空间不分配。本布局不承诺兼容任意既有卡的分区方式。卡初始化沿用现有052 SDHC假设，不新增任意容量类别支持。

冻结 BMP SHA256 为 `938219a71dde50745624d8821554cca0822c748149b2e3f9cd8d31eccfe26516`；文件 CRC32 `47E2A01D`，按物理升地址排列的16bit标签 CRC32 `A1E4D4E1`。上位机工具与 RTL 均检查该身份。

## 制作镜像

使用052第五步已有 PCM 转换流程得到真实的裸 PCM 素材，按需要传入1–4槽。以下素材路径为示例，应替换成自己的真实文件路径：

```powershell
$fdiPkg = "D:/Download/嵌赛fpga_安路/eg4s20bg256/topic1_media_terminal/visual_workspace/rtl_handoff/m6_full_display_integration"
python "$fdiPkg/scripts/make_controlled_card.py" build --output "$fdiPkg/m6_card_ready.img" --pcm "D:/pcm/WAV1.WAV" "D:/pcm/WAV2.WAV" "D:/pcm/WAV3.WAV" "D:/pcm/WAV4.WAV"
python "$fdiPkg/scripts/make_controlled_card.py" verify "$fdiPkg/m6_card_ready.img"
```

工具只创建新普通镜像文件，拒绝覆盖已有输出、拒绝直接写物理设备；会生成配套 `.img.json`，登记输入素材 SHA、完整镜像 SHA、布局及双 CRC。素材经完整 FAT 链重建校验，不只是检查目录项。无需额外 Python 包。

`sim/round2_card/label_only.img` 是已验证的标签单独测试镜像，PCM槽为空，不能作为赛题完整素材卡；四槽工具验证使用合成数据，未冒充真实音频素材。

本轮另已生成 `sim/round2_card/label_pcm_short_real.img`，只读引用052已保留的真实短素材，四槽分别10.1/12.2/14.3/16.4秒。完整镜像和素材簇链重建均验证通过，镜像SHA256为 `db41b9c551ccde1c0ecdad878e997357ff9443f56ff095096e69407933f3a5f0`，输入身份与结果见 `sim/round2_card/REAL_PCM_IMAGE_VALIDATION.json`。这是共卡短素材验收镜像，未写实体卡、未表示本FDI位已合入真音频应用；正式长曲演示布局仍需与052后续统一，不能把本工具的20秒限制扩称为任意长曲支持。

## 写卡及读回

1. 准备专用 TF 卡并确认其数据已备份。整盘镜像写入会重写 MBR 和目标分区，不能用普通“复制文件到卡”代替。
2. 使用已有可信的镜像写卡工具，明确选中该 TF 卡整盘，将新生成的 `.img` 以 raw/DD 方式写入并启用写后校验。本工具不执行此步骤。
3. 写后不要重新分区或全盘格式化。用写卡工具读回前128MiB为新 `.img`，运行上述 `verify`，并与制作时的镜像及各 PCM SHA 对照。先完成读回，再允许系统对该受控分区写入其他内容。
4. 安全弹出后装入主板；标签载入通过文件/物理标签双 CRC 后开放显示。原PCM应用按受控 FAT32 根槽读取，标签LBA与其文件簇链无交集。

本包未写实体 TF 卡，未确认具体卡型/电气/SPI裕量，也未代签上板。无卡故障码模型为 `83`；扇区 CRC16 错为 `05`；BMP头错误 `40`、文件 CRC32 错 `41`、SDRAM标签读回 CRC32 错 `48`；主板现有数码管显示 `60000+故障码十进制值`，LED诊断路径保持。
