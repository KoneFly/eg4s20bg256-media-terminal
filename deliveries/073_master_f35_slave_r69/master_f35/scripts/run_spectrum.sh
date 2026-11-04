#!/usr/bin/env bash
# 频谱叠加单元台：平滑、横向/纵向渐变、音柱与波形混合，逐像素与独立模型比对
export OBJCACHE=ccache
set -eu
here="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$here"
mkdir -p sim
b="/tmp/f35_spec"; rm -rf "$b"
verilator --binary --timing -j 0 -O2 -DSIMULATION -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-MULTIDRIVEN \
  --top-module tb_spectrum_smooth --Mdir "$b" -o sim tb/tb_spectrum_smooth.sv \
  rtl/t073_spectrum_overlay.v rtl/spectrum_row_fill.v rtl/spectrum_frequency_axis.v rtl/pixel_switch_sync.v \
  > sim/spec_build.log 2>&1 || { grep -E "%Error" sim/spec_build.log | head -20; exit 1; }
"$b/sim" > sim/spec.log 2>&1 || true
grep -E "SUMMARY|RESULT|ERROR" sim/spec.log | head -20
