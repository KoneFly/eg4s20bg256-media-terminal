#!/usr/bin/env bash
# 把大体量仿真数据(镜像/期望 hex)放到 WSL 原生 ext4(/tmp/f35_data), sim/ 下用符号链接指向它。
# 原因: /mnt/d 的 9P 文件系统写入比 ext4 慢约 4 倍。日志/报告仍留在 sim/ 便于从 Windows 查看。
set -eu
here="$(cd -- "$(dirname -- "$0")/.." && pwd)"
d=/tmp/f35_data; mkdir -p "$d"
for f in bmp_in.hex bmp_expect.hex vid_img.hex vid_expect.hex aud_expect.hex fat_img.hex fat_expect.txt; do
  p="$here/sim/$f"
  if [ ! -L "$p" ]; then rm -f "$p"; ln -s "$d/$f" "$p"; fi
done
echo "scratch -> $d"
