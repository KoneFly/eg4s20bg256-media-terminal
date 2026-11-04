#!/usr/bin/env bash
# 等价性对照台：淡入淡出混合（移位加 vs 乘法）与 WAV 解析（新旧实现）逐位/逐样本比对
export OBJCACHE=ccache
set -eu
here="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$here"
mkdir -p sim
sed 's/module t072_wav_parser/module ref_wav_parser/' rtl/t072_wav_parser.v > sim/ref_wav_parser.v
sed 's/module transition_engine_curtain (/module te_mul (/' rtl/transition_engine_curtain.v > sim/te_mul.v
g++ -O2 -std=c++17 -o tools/gen_wav_cases tools/gen_wav_cases.cpp
tools/gen_wav_cases > /dev/null
b="/tmp/f35_eq"; rm -rf "$b"
verilator --binary --timing -j 0 -O2 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-MULTIDRIVEN \
  --top-module tb_fade_equiv --Mdir "$b" -o sim tb/tb_fade_equiv.sv rtl/transition_engine_curtain.v sim/te_mul.v \
  > sim/eq_build.log 2>&1 || { grep -E "%Error" sim/eq_build.log | head -20; exit 1; }
"$b/sim" > sim/eq_fade.log 2>&1 || true
grep -E "SUMMARY|RESULT|ERROR" sim/eq_fade.log | head -5
b2="/tmp/f35_weq"; rm -rf "$b2"
verilator --binary --timing -j 0 -O2 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-MULTIDRIVEN \
  --top-module tb_wav_equiv --Mdir "$b2" -o sim tb/tb_wav_equiv.sv sim/ref_wav_parser.v rtl/t072_wav_parser.v \
  > sim/eqw_build.log 2>&1 || { grep -E "%Error" sim/eqw_build.log | head -20; exit 1; }
"$b2/sim" > sim/eq_wav.log 2>&1 || true
grep -E "COVER|SUMMARY|RESULT|ERROR" sim/eq_wav.log | head -5
