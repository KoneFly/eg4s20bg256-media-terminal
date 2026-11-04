"""只读核验A4历史位的门级/物理OR接线及d2高13位选通；不改封存文件。"""
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "experiments/board_0x46_A4_work"
GATE = WORK / "td_run/check_a4/gate_netlist.v"
ROUTE = WORK / "td_run/bit_a4_final/route_netlist.v"
HISTORY = r"\u_clock_probe/ever_watchdog"
COUNTER = r"\u_display/u_label_store/debug_progress"
CTRL = r"\u_display/u_label_store/u_check_buffer/wr_clk"
KEY1 = r"\u_decimal/rst_n"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cells(text, family):
    pattern = rf"^\s*({family}_\w+)\s*(?:#\((.*?)\)\s*)?(\\\S+|\w+)\s*\((.*?)\);"
    for kind, params, name, body in re.findall(pattern, text, re.M | re.S):
        yield dict(kind=kind, name=name,
                   params=dict(re.findall(r"\.(\w+)\(([^()]*)\)", params or "")),
                   ports={k: v.strip() for k, v in re.findall(r"\.(\w+)\(([^()]*)\)", body)})


def literal(expression):
    match = re.fullmatch(r"(\d+)'([bh])([0-9a-fA-F]+)", expression)
    assert match, expression
    return int(match[1]), int(match[3], 2 if match[2] == "b" else 16)


gate_text = GATE.read_text(encoding="utf-8")
route_text = ROUTE.read_text(encoding="utf-8")
vectors = {n.strip(): (int(h), int(l)) for h, l, n in
           re.findall(r"(?m)^  wire \[(\d+):(\d+)\] ([^;]+);", route_text)}


def bits(expression):
    expression = expression.strip()
    if expression.startswith("{"):
        return [bit for part in reversed(expression[1:-1].split(",")) for bit in bits(part)]
    if re.fullmatch(r"\d+'[bh][0-9a-fA-F]+", expression):
        width, value = literal(expression)
        return [f"1'b{value >> i & 1}" for i in range(width)]
    span = re.fullmatch(r"(.+)\s\[(\d+):(\d+)\]", expression)
    if span:
        return [f"{span[1]} [{i}]" for i in range(int(span[3]), int(span[2]) + 1)]
    if expression in vectors:
        high, low = vectors[expression]
        return [f"{expression} [{i}]" for i in range(low, high + 1)]
    return [expression]


gate_cells = list(cells(gate_text, "AL_MAP"))
gate_luts = {c["ports"]["o"]: c for c in gate_cells if c["kind"].startswith("AL_MAP_LUT")}
gate_history = []
for cell in gate_cells:
    match = re.fullmatch(re.escape(HISTORY) + r"_reg\[(\d+)\]", cell["name"])
    if not match:
        continue
    index = int(match[1])
    port, params = cell["ports"], cell["params"]
    assert port["q"] == f"{HISTORY} [{index}]"
    assert port["clk"] == CTRL and port["sr"] == KEY1
    assert params["SRMODE"] == '"ASYNC"' and params["SRMUX"] == '"INV"'
    assert params["REGSET"] == '"RESET"' and params["CEMUX"] == '"1"'
    lut = gate_luts[port["d"]]
    assert lut["kind"] == "AL_MAP_LUT2" and literal(lut["params"]["INIT"])[1] == 14
    assert {lut["ports"]["a"], lut["ports"]["b"]} == {port["q"], f"{COUNTER} [{index}]"}
    gate_history.append(dict(bit=index, register=cell, or_lut=lut))
assert sorted(r["bit"] for r in gate_history) == list(range(29))

physical_history = []
for cell in cells(route_text, "EG_PHY"):
    port, params = cell["ports"], cell["params"]
    for lane, q in enumerate(bits(port.get("q", "2'b00"))):
        match = re.fullmatch(re.escape(HISTORY) + r" \[(\d+)\]", q)
        if not match:
            continue
        index = int(match[1])
        assert port["clk"] == CTRL and port["sr"] == KEY1
        assert params["SRMODE"] == '"ASYNC"' and params["SRMUX"] == '"INV"'
        assert params[f"REG{lane}_REGSET"] == '"RESET"'
        assert params[f"REG{lane}_SD"] == '"F"' and params["CEMUX"] == '"1"'
        assert params["MODE"] == '"LOGIC"'
        mslice = cell["kind"] == "EG_PHY_MSLICE"
        width = 4 if mslice else 5
        if not mslice:
            assert params[f"LSFMUX{lane}"] == '"FUNC5"'
        truth = literal(params[f"INIT_LUT{lane}" if mslice else f"INIT_LUTF{lane}"])[1]
        if not mslice:
            truth |= literal(params[f"INIT_LUTG{lane}"])[1] << 16
        inputs = [bits(port.get(pin, "2'b00"))[lane] for pin in "abcde"[:width]]
        assert inputs[2] == f"{COUNTER} [{index}]" and inputs[3] == q
        # C/D之外所有LUT引脚取值均遍历，避免把缺省/悬空输入当成固定值。
        for assignment in range(1 << width):
            expected = bool(assignment & 4 or assignment & 8)
            assert (truth >> assignment & 1) == expected, (cell["name"], index, assignment)
        physical_history.append(dict(bit=index, lane=lane, truth=truth, inputs=inputs, cell=cell))
assert sorted(r["bit"] for r in physical_history) == list(range(29))


def gate_evaluate(output, known):
    @lru_cache(maxsize=None)
    def evaluate(net):
        if net in known:
            return known[net]
        if net not in gate_luts:
            return None
        cell = gate_luts[net]
        width = int(cell["kind"].removeprefix("AL_MAP_LUT"))
        values = [evaluate(cell["ports"][chr(97 + i)]) for i in range(width)]
        unknown = [i for i, v in enumerate(values) if v is None]
        truth = literal(cell["params"]["INIT"])[1]
        outcomes = set()
        for assignment in range(1 << len(unknown)):
            address = sum((v or 0) << i for i, v in enumerate(values))
            address |= sum((assignment >> k & 1) << i for k, i in enumerate(unknown))
            outcomes.add(truth >> address & 1)
        return next(iter(outcomes)) if len(outcomes) == 1 else None
    return evaluate(output)


page_checks = []
base = {"1'b0": 0, "1'b1": 1}
base.update({rf"\u_decimal/page [{i}]": 2 >> i & 1 for i in range(3)})
sw_nets = {n for c in gate_luts.values() for n in c["ports"].values()
           if re.fullmatch(r"(?:\\)?sw\[0\](?:_dup_\d+)?", n)}
assert sw_nets
base.update({n: 1 for n in sw_nets})
for bit in range(13):
    for value in (0, 1):
        known = dict(base, **{f"{HISTORY} [{bit + 16}]": value})
        output = f"display_value[{bit}]"
        actual = gate_evaluate(output, known)
        assert actual == value, (bit, value, actual)
        page_checks.append(dict(display_bit=bit, history_bit=bit + 16, input=value, output=actual))

result = dict(status="PASS_A4_HISTORY_OR_AND_D2_GATE_SELECTION",
              gate_sha256=sha(GATE), route_sha256=sha(ROUTE),
              gate_history=gate_history, physical_history=physical_history, d2_gate_checks=page_checks,
              readback_decode=dict(d1=65535, d2=59392, d2_hex="E800", high13_history=2048,
                                   high_history_bits_set=[27], bit16_history=0, d4=64,
                                   ctrl_edge_seen=1, start_seen=0, boot_exit_seen=0, low_wrap_seen=0,
                                   ctrl_reset_seen=0, pll_unlock_seen=0, bad_state_seen=0,
                                   d5=268, d6=4096, eng_init=0, init_ready=0,
                                   observed_store=0, observed_init=0, observed_reader=16),
              limits="原生门级与物理OR真值/复位/时钟接线及门级d2选通证据；没有bit读回、板上频率或进位传播实测。上板d0/d7及KEY1起始条件尚待确认；未证明物理全显示链或瞬态复位捕获率。")
output = ROOT / "doc/output/A4_PROBE_HISTORY_STATIC_20261006.json"
serialized = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
if output.exists():
    assert output.read_text(encoding="utf-8") == serialized, "禁止覆盖不同证据"
else:
    output.write_text(serialized, encoding="utf-8")
print(json.dumps(dict(status=result["status"], gate_history_bits=len(gate_history),
                      physical_history_bits=len(physical_history), d2_selection_checks=len(page_checks)),
                 ensure_ascii=False))
