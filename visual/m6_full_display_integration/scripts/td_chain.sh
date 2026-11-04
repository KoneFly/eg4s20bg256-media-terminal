#!/usr/bin/env bash
# 依次执行已验证的TD实现流程；任一阶段RESULT不符即停止。用法: td_chain.sh <实验目录> <标签后缀> [place]
set -u
cd "$1" || exit 1
s=$2
res(){ node -e "const r=require('./td_run/$1/RESULT.json');console.log('$1',r.status,r.bit_status||'',r.measured&&r.measured.mslices,JSON.stringify(r.sta))"; }
st(){ node -e "process.exit(require('./td_run/$1/RESULT.json').status==='$2'?0:1)"; }
run(){ powershell -NoProfile -File scripts/run_round2.ps1 "$@" -MappingStrategy LogicLevelOptimize >/dev/null 2>&1; }
if [ "${3:-}" != place ]; then
run -Tag synth_$s -Mode synth; res synth_$s; st synth_$s PASS_STAGE || exit 2
run -Tag check_f2 -Mode check -InputTag synth_$s; res check_f2; st check_f2 PASS_STAGE || exit 2
python scripts/audit_round2_cdc.py td_run/check_f2 gate | tail -c 120
fi
run -Tag place_$s -Mode place -InputTag check_f2 -PlaceSeed 2; res place_$s; st place_$s PASS_STAGE || exit 2
python scripts/remap_physical_sdc.py td_run/place_$s place
run -Tag route_$s -Mode route -InputTag place_$s -RouteEffort high -FlowThreads 1; res route_$s
python scripts/remap_physical_sdc.py td_run/route_$s route
run -Tag hold_${s}_clock -Mode hold -InputTag route_$s -HoldStrategy clock; res hold_${s}_clock
python scripts/remap_physical_sdc.py td_run/hold_${s}_clock route
run -Tag hold_${s}_pad16 -Mode hold -InputTag hold_${s}_clock -HoldStrategy pad; res hold_${s}_pad16; st hold_${s}_pad16 PASS_STAGE || exit 3
python scripts/remap_physical_sdc.py td_run/hold_${s}_pad16 route
python scripts/audit_round2_cdc.py td_run/hold_${s}_pad16 route >/dev/null; node scripts/audit_round2_rom.cjs td_run/hold_${s}_pad16 route >/dev/null
run -Tag bit_$s -Mode bit -InputTag hold_${s}_pad16; res bit_$s; st bit_$s PASS_STAGE || exit 4
python scripts/audit_round2_cdc.py td_run/bit_$s route >/dev/null; node scripts/audit_round2_rom.cjs td_run/bit_$s route >/dev/null
node -e "const c=require('./td_run/bit_$s/CDC_AUDIT.json'),r=require('./td_run/bit_$s/ROM_AUDIT.json');console.log('SIGNOFF',c.status,c.source_D_CE_alias_exemptions,c.accidental_pixel_shift_mcp_endpoints,r.status,r.words)"
sha256sum td_run/bit_$s/eth_udp_m6_master_top.bit
