#!/usr/bin/env bash
# FAT32 扫描台：生成卡镜像与期望 extent -> 编译 -> 运行
export OBJCACHE=ccache
set -eu
here="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$here"
bash scripts/wsl_scratch.sh > /dev/null
mkdir -p sim
python3 -I scripts/make_fat_image.py > /dev/null
b="/tmp/f35_fat"; rm -rf "$b"
verilator --binary --timing -j 0 -O2 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-MULTIDRIVEN --top-module tb_fat32_scan \
  --Mdir "$b" -o sim tb/tb_fat32_scan.sv tb/sd_card_model.sv tb/EG_LOGIC_ODDR.v \
  rtl/sd_crc.v rtl/sd_clkgen.v rtl/sd_phy.v rtl/sd_cmd.v rtl/sd_dat_rx.v rtl/sd_host.v rtl/fat32_scan.v \
  > sim/fat_build.log 2>&1 || { grep -E "%Error" sim/fat_build.log | head -20; exit 1; }
"$b/sim" +img=sim/fat_img.hex > sim/fat.log 2>&1 || true
rm -rf "$b"
grep -E "SUMMARY|RESULT|ERROR" sim/fat.log | head -30
