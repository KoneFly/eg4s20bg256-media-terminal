#!/usr/bin/env bash
# 主板门禁流程：后台运行 b1_gate.tcl，监管卡死，判定门禁，达标后生成位流。
# 用法：bash run_b1.sh [锁文件路径]      在 td_run/ 下执行
set -u
here="$(cd -- "$(dirname -- "$0")/.." && pwd)"
td="$here/td_run"
tag="${1:-run}"
TD_EXE="D:/AnLu/bin/td_commands_prompt.exe"
STALE_S=1500        # 日志 25 分钟无增长判卡死（时序修复阶段可能长时间静默）
TOTAL_S=5400        # 总时长上限 90 分钟
cd "$td" || { echo "FAIL no td_run"; exit 1; }

arch="hist/$(date +%H%M%S)_$tag"
mkdir -p "$arch"
mv gate_b1.* td_gate.log td_bitgen.log master_f35.bit trial_bitgen_check.timing "$arch"/ 2>/dev/null
rm -f td_20*.log td_20*.logw

echo "START $tag $(date +%T)"
if [ $# -ge 1 ]; then
  python -I td_serial.py b1_gate.tcl td_gate.log "$1" &
else
  "$TD_EXE" b1_gate.tcl > td_gate.log 2>&1 &
fi
pid=$!
while kill -0 "$pid" 2>/dev/null && [ ! -s td_gate.log ]; do sleep 10; done
t0=$(date +%s); last_size=0; last_change=$t0; stage=""
while kill -0 "$pid" 2>/dev/null; do
  sleep 15
  now=$(date +%s)
  size=$(stat -c %s td_gate.log 2>/dev/null || echo 0)
  [ "$size" != "$last_size" ] && { last_size=$size; last_change=$now; }
  s=$(grep -o "optimize_rtl\|optimize_gate\|PHY-1001 : Stage [0-9] | [A-Za-z ]*\|fix_hold" td_gate.log 2>/dev/null | tail -1)
  if [ -n "$s" ] && [ "$s" != "$stage" ]; then stage="$s"; echo "STAGE $(( (now-t0)/60 ))min $stage"; fi
  if [ $((now-last_change)) -gt $STALE_S ] || [ $((now-t0)) -gt $TOTAL_S ]; then
    echo "HANG after $(( (now-t0)/60 ))min stage=$stage, killing"
    taskkill //F //T //PID "$(ps -W | awk -v p="$pid" '$1==p{print $4}')" >/dev/null 2>&1
    kill "$pid" 2>/dev/null
    taskkill //F //IM td_commands_prompt.exe >/dev/null 2>&1
    echo "FAIL hang"; exit 2
  fi
done

if grep -q "ERROR" td_gate.log || ! grep -q "MASTER_B1_COMPLETE" td_gate.log; then
  echo "FAIL td_error: $(grep -m3 "ERROR" td_gate.log | tr '\n' ' ' | cut -c1-300)"
  exit 3
fi
[ -f gate_b1.ts ] || { echo "FAIL no_report"; exit 4; }

P=$(sed -n 's/^#plb *\([0-9]*\).*/\1/p' gate_b1.area)
S=$(sed -n 's/SWNS: \([0-9.-]*\)ns.*/\1/p' gate_b1.ts)
H=$(sed -n 's/HWNS: \([0-9.-]*\)ns.*/\1/p' gate_b1.ts)
echo "RESULT PLB=$P SWNS=$S HWNS=$H"
if python -I -c "import sys; sys.exit(0 if ($P<=2450 and $S>=3.690 and $H>=0.214) else 1)"; then
  echo "GATE_PASS, bitgen"
  if [ $# -ge 1 ]; then timeout 1200 python -I td_serial.py trial_bitgen.tcl td_bitgen.log "$1"
  else timeout 1200 "$TD_EXE" trial_bitgen.tcl > td_bitgen.log 2>&1; fi
  if [ -f master_f35.bit ]; then
    echo "BIT $(sha256sum master_f35.bit | cut -c1-16) $(stat -c %s master_f35.bit)B"
    echo "DONE pass"; exit 0
  fi
  echo "FAIL bitgen"; exit 5
fi
grep -n "^Slack  \|^Begin Point\|^End Point" gate_b1.timing | head -3 | sed 's/ (rising.*//' | while read -r l; do echo "PATH $l"; done
echo "FAIL gate"; exit 6
