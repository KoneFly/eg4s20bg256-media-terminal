#!/usr/bin/env bash
# BMP 加载器(含行缓存写口寄存)多尺寸回归: 期望帧由 tools/gen_golden 独立计算
export OBJCACHE=ccache
set -eu
here="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$here"
mkdir -p sim
g++ -O2 -std=c++17 -o tools/gen_golden tools/gen_golden.cpp
b="/tmp/f35_bmp"; rm -rf "$b"
verilator --binary --timing -j 0 -O2 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-MULTIDRIVEN --top-module tb_bmp_loader \
  --Mdir "$b" -o sim tb/tb_bmp_loader.sv rtl/bmp_page_loader.v rtl/bmp_stream_align_shim.v \
  rtl/bmp24_to_rgb565_converter.v rtl/rgb888_to_rgb565.v rtl/bmp_top_down_observer.v rtl/bmp_resampler.v \
  > sim/bmp_build.log 2>&1 || { grep -E "%Error" sim/bmp_build.log | head -20; exit 1; }
for c in "640 480 0 0" "320 240 1 30" "200 150 0 0" "1920 1080 0 20" "1024 768 1 0" "100 900 0 0" "641 481 1 10" "33 17 0 0"; do
  set -- $c
  tools/gen_golden bmp "$1" "$2" "$3" 1 > /dev/null
  n=$(wc -l < sim/bmp_in.hex)
  "$b/sim" +n="$n" +bp="$4" > "sim/bmp_case.log" 2>&1 || true
  echo "$1x$2 td$3 bp$4: $(grep -E 'RESULT' sim/bmp_case.log | head -1)"
done
rm -rf "$b"
