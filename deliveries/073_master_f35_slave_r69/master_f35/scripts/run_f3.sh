#!/usr/bin/env bash
# 主板整板系统台(WSL Verilator): 生成独立黄金与卡镜像 -> 编译 -> 运行
export OBJCACHE=ccache
set -eu
here="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$here"
mkdir -p sim
rm -f sim/master.log   # 编译失败时不留旧日志, 避免误读
g++ -O2 -std=c++17 -o tools/gen_f0 tools/gen_f0.cpp
tools/gen_f0
b="/tmp/f35_sim"
if [ ! -x "$b/sim" ] || [ "${REBUILD:-0}" = 1 ]; then
  rm -rf "$b"
  verilator --binary --timing -j 0 -O2 -DSIMULATION -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-MULTIDRIVEN -Wno-PINCONNECTEMPTY \
    -Irtl --top-module tb_f3_system --Mdir "$b" -o sim \
    tb/tb_f3_system.sv tb/sd_card_model.sv tb/sim_stubs.v tb/EG_LOGIC_ODDR.v tb/EG_PHY_SDRAM_2M_32.v \
    $(cat sim/sim_files.f) > sim/master_build.log 2>&1 || { grep -E "%Error" sim/master_build.log | head -20; exit 1; }
fi
"$b/sim" +img=sim/f0_img.hex "$@" > sim/master.log 2>&1 || true
grep -E "STEP|SUMMARY|RESULT|ERROR" sim/master.log | head -60
