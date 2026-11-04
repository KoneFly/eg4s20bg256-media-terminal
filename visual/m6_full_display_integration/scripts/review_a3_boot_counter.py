"""只读复查A3原生计数寄存器、启动比较器及BOOT下一拍；不覆盖封存产物。"""
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "experiments/board_0x46_A3_work"
GATE = WORK / "td_run/check_a3/gate_netlist.v"
ROUTE = WORK / "td_run/bit_a3_final/route_netlist.v"
PREFIX = r"\u_display/u_label_store/"
COUNTER = PREFIX + "debug_progress"
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
source = GATE.read_text(encoding="utf-8")
luts, registers = {}, []
for match in re.finditer(r"(?m)^  AL_MAP_\w+[\s\S]*?;[^\n]*", source):
    block = match.group()
    name = re.search(r"\n    (\\\S+)\s+\(", block)
    if not name:
        continue
    ports = {k: v.strip() for k, v in re.findall(r"\.(\w+)\(([^()]*)\)", block)}
    record = dict(instance=name[1], ports=ports, text=block)
    if block.startswith("  AL_MAP_LUT"):
        init = re.search(r"\.INIT\(\d+'h([\da-fA-F]+)\)", block)
        if init:
            record.update(width=int(re.search(r"AL_MAP_LUT(\d+)", block)[1]), init=int(init[1], 16))
            luts[ports["o"]] = record
    elif block.startswith("  AL_MAP_SEQ"):
        registers.append(record)

@lru_cache(maxsize=None)
def cube(net, value):
    if net not in luts:
        return ((net, value),)
    cell = luts[net]
    inputs = [cell["ports"][chr(97 + i)] for i in range(cell["width"])]
    variables = list(dict.fromkeys(n for n in inputs if n not in ("1'b0", "1'b1")))
    table = []
    for assignment in range(1 << len(variables)):
        vals = {n: (assignment >> i) & 1 for i, n in enumerate(variables)}
        vals.update({"1'b0": 0, "1'b1": 1})
        table.append((cell["init"] >> sum(vals[n] << i for i, n in enumerate(inputs))) & 1)
    active = [i for i in range(len(variables)) if any(table[j] != table[j ^ (1 << i)] for j in range(len(table)))]
    hits = [j for j in range(1 << len(active)) if table[sum(((j >> k) & 1) << i for k, i in enumerate(active))] == value]
    if len(hits) != 1:
        raise ValueError("不是单一合取条件")
    leaves = {}
    for k, i in enumerate(active):
        for leaf, bit in cube(variables[i], (hits[0] >> k) & 1):
            if leaf in leaves and leaves[leaf] != bit:
                raise ValueError("矛盾条件")
            leaves[leaf] = bit
    return tuple(sorted(leaves.items()))

comparisons = []
for net in luts:
    if not net.startswith(PREFIX):
        continue
    try:
        leaves = dict(cube(net, 1))
    except ValueError:
        continue
    indices = {}
    for leaf, bit in leaves.items():
        match = re.fullmatch(re.escape(COUNTER) + r" \[(\d+)\]", leaf)
        if match:
            indices[int(match[1])] = bit
    if set(indices) == set(range(29)):
        constant = sum(v << k for k, v in indices.items())
        if constant in (499999, 499999999):
            comparisons.append(dict(output=net, constant=constant, leaves=leaves))
assert {c["constant"] for c in comparisons} == {499999, 499999999}, comparisons
physical = ROUTE.read_text(encoding="utf-8")
vectors = {name.strip(): (int(high), int(low)) for high, low, name in re.findall(r"(?m)^  wire \[(\d+):(\d+)\] ([^;]+);", physical)}

def bits(expression):
    expression = expression.strip()
    if expression.startswith("{"):
        return [bit for part in reversed(expression[1:-1].split(",")) for bit in bits(part)]
    literal = re.fullmatch(r"(\d+)'([bh])([0-9a-fA-F]+)", expression)
    if literal:
        value = int(literal[3], 2 if literal[2] == "b" else 16)
        return [f"1'b{(value >> i) & 1}" for i in range(int(literal[1]))]
    span = re.fullmatch(r"(.+)\s\[(\d+):(\d+)\]", expression)
    if span:
        return [f"{span[1]} [{i}]" for i in range(int(span[3]), int(span[2]) + 1)]
    if expression in vectors:
        high, low = vectors[expression]
        return [f"{expression} [{i}]" for i in range(low, high + 1)]
    return [expression]

def literal_value(expression):
    width, base, value = re.fullmatch(r"(\d+)'([bh])([0-9a-fA-F]+)", expression).groups()
    return int(value, 2 if base == "b" else 16)

physical_drivers = {}
for match in re.finditer(r"(?m)^  EG_PHY_[ML]SLICE[\s\S]*?;[^\n]*", physical):
    block = match.group()
    name = re.search(r"\n    (\\\S+)\s+\(", block)
    if not name:
        continue
    ports = {k: v.strip() for k, v in re.findall(r"\.(\w+)\(([^()]*)\)", block[name.start():])}
    params = {k: v.strip() for k, v in re.findall(r"(?m)^    \.(\w+)\(([^()]*)\)", block[:name.start()])}
    if params.get("MODE") != '"LOGIC"':
        continue
    mslice = block.startswith("  EG_PHY_MSLICE")
    for lane, output in enumerate(bits(ports.get("f", "2'b00"))):
        if output.startswith("open_") or output.startswith("1'b"):
            continue
        keys = [f"INIT_LUT{lane}"] if mslice else [f"INIT_LUTF{lane}", f"INIT_LUTG{lane}"]
        if any(key not in params for key in keys):
            continue
        width = 4 if mslice or params.get(f"LSFMUX{lane}", '"LUTF"') == '"LUTF"' else 5
        if not mslice and params.get(f"LSFMUX{lane}", '"LUTF"') not in ('"LUTF"', '"FUNC5"'):
            continue
        truth = literal_value(params[keys[0]])
        if width == 5:
            truth |= literal_value(params[keys[1]]) << 16
        inputs = [bits(ports.get(pin, "2'b00"))[lane] for pin in "abcde"[:width]]
        physical_drivers[output] = dict(instance=name[1], inputs=inputs, truth=truth, text=block)
    # MSLICE的双LUT4经MI0选通形成LUT5；仅接受两半ABCD实际接线相同的情况。
    if mslice and params.get("MSFXMUX") == '"ON"' and "fx" in ports:
        pairs = [bits(ports.get(pin, "2'b00")) for pin in "abcd"]
        if all(pair[0] == pair[1] for pair in pairs):
            output = bits(ports["fx"])[0]
            inputs = [pair[0] for pair in pairs] + [bits(ports.get("mi", "2'b00"))[0]]
            truth = literal_value(params["INIT_LUT0"]) | (literal_value(params["INIT_LUT1"]) << 16)
            physical_drivers[output] = dict(instance=name[1], inputs=inputs, truth=truth, text=block)

@lru_cache(maxsize=None)
def physical_cube(net, wanted):
    if net not in physical_drivers:
        return ((net, wanted),)
    cell = physical_drivers[net]
    variables = list(dict.fromkeys(n for n in cell["inputs"] if n not in ("1'b0", "1'b1")))
    table = []
    for assignment in range(1 << len(variables)):
        vals = {n: (assignment >> i) & 1 for i, n in enumerate(variables)}
        vals.update({"1'b0": 0, "1'b1": 1})
        table.append((cell["truth"] >> sum(vals[n] << i for i, n in enumerate(cell["inputs"]))) & 1)
    active = [i for i in range(len(variables)) if any(table[j] != table[j ^ (1 << i)] for j in range(len(table)))]
    hits = [j for j in range(1 << len(active)) if table[sum(((j >> k) & 1) << i for k, i in enumerate(active))] == wanted]
    if len(hits) != 1:
        raise ValueError(f"不是单一物理合取条件:{net}")
    leaves = {}
    for k, i in enumerate(active):
        for leaf, bit in physical_cube(variables[i], (hits[0] >> k) & 1):
            if leaf in leaves and leaves[leaf] != bit:
                raise ValueError("矛盾物理条件")
            leaves[leaf] = bit
    return tuple(sorted(leaves.items()))

route_comparisons = []
for comparison in comparisons:
    leaves = dict(physical_cube(comparison["output"], 1))
    assert leaves == comparison["leaves"], (comparison["output"], leaves)
    route_comparisons.append(dict(output=comparison["output"], constant=comparison["constant"], gate_route_leaves_identical=True, leaves=leaves))

state_regs = [r for r in registers if re.fullmatch(re.escape(PREFIX) + r"state_reg\[[0-3]\]", r["instance"])]
counter_regs = [r for r in registers if re.fullmatch(re.escape(PREFIX) + r"watchdog_reg\[\d+\]", r["instance"])]
assert len(state_regs) == 4 and len(counter_regs) == 29
for r in counter_regs:
    index = int(re.search(r"\[(\d+)\]$", r["instance"])[1])
    assert r["ports"]["q"] == COUNTER + f" [{index}]"
    assert r["ports"]["clk"] == PREFIX + "u_check_buffer/wr_clk"
    assert r["ports"]["sr"] == "ctrl_reset_sync[1]"
    assert r["ports"]["ce"] == PREFIX + "debug_snapshot_b_n"

boot_checks = []
for count, expected in [(65534, 0), (65535, 0), (65536, 0), (499998, 0), (499999, 1), (500000, 0)]:
    known = {PREFIX + f"state [{i}]": 0 for i in range(4)}
    known.update({COUNTER + f" [{i}]": (count >> i) & 1 for i in range(29)})
    known.update({"1'b0": 0, "1'b1": 1})

    @lru_cache(maxsize=None)
    def evaluate(net):
        if net in known:
            return known[net]
        if net not in luts:
            return None
        cell = luts[net]
        inputs = [evaluate(cell["ports"][chr(97 + i)]) for i in range(cell["width"])]
        unknown = [i for i, value in enumerate(inputs) if value is None]
        outputs = set()
        for assignment in range(1 << len(unknown)):
            index = sum((value or 0) << i for i, value in enumerate(inputs))
            index |= sum(((assignment >> k) & 1) << i for k, i in enumerate(unknown))
            outputs.add((cell["init"] >> index) & 1)
        return next(iter(outputs)) if len(outputs) == 1 else None

    next_bits = [evaluate(next(r for r in state_regs if r["instance"] == PREFIX + f"state_reg[{i}]")["ports"]["d"]) for i in range(4)]
    assert next_bits == [(expected >> i) & 1 for i in range(4)], (count, next_bits)
    ce = evaluate(PREFIX + "debug_snapshot_b_n")
    clear = evaluate(PREFIX + "mux122_syn_102")
    assert ce == 1 and clear == 0, (count, ce, clear)
    boot_checks.append(dict(current_state=0, watchdog=count, next_state=expected, counter_ce=ce, synchronous_counter_clear=clear, other_inputs="unknown, conservatively propagated"))

ripple, physical_regs = [], []
for match in re.finditer(r"^\s*(EG_PHY_\w+)\s*(?:#\((.*?)\)\s*)?(\\\S+|\w+)\s*\((.*?)\);", physical, re.M | re.S):
    kind, params, name, body = match.groups()
    ports = {k: v.strip() for k, v in re.findall(r"\.(\w+)\((.*?)\)", body, re.S)}
    if re.search(re.escape(COUNTER) + r"\s*\[(\d+)(?::\d+)?\]", ports.get("q", "")):
        physical_regs.append(dict(instance=name, parameters=params, ports=ports))
    if re.search(re.escape(PREFIX + "watchdog_b7") + r"\s*\[", ports.get("f", "") + ports.get("fx", "")):
        assert kind == "EG_PHY_LSLICE" and '.MODE("RIPPLE")' in params
        ripple.append(dict(instance=name, parameters=params, ports=ports))
assert len(ripple) == 8
for previous, current in zip(ripple, ripple[1:]):
    assert current["ports"]["fci"] == previous["ports"]["fco"]
bits = []
for r in physical_regs:
    for high, low in re.findall(re.escape(COUNTER) + r"\s*\[(\d+)(?::(\d+))?\]", r["ports"]["q"]):
        bits.extend(range(int(low), int(high) + 1) if low else [int(high)])
    assert r["ports"]["clk"] == PREFIX + "u_check_buffer/wr_clk"
    assert r["ports"]["ce"] == PREFIX + "debug_snapshot_b_n"
    assert re.fullmatch(r"(?:\\)?ctrl_reset_sync\[1\](?:_dup_\d+)?", r["ports"]["sr"])
assert sorted(bits) == list(range(29)), bits
result = dict(status="PASS_STATIC_BOOT_COUNTER_REVIEW", gate_sha256=sha(GATE), route_sha256=sha(ROUTE),
              comparisons=comparisons, route_comparisons=route_comparisons, boot_checks=boot_checks,
              gate_counter_registers=counter_regs, physical_counter_registers=physical_regs, ripple_chain=ripple,
              limits="比较器LUT INIT及寄存器/进位连接静态证据；没有解密原厂RIPPLE模型或实测计数值，不能证明板上进位传播、复位无短脉冲或频率正确。")
output = ROOT / "doc/output/A3_PROBE_BOOT_COUNTER_STATIC_20261006.json"
serialized = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
if output.exists():
    assert output.read_text(encoding="utf-8") == serialized, "禁止覆盖不同证据"
else:
    output.write_text(serialized, encoding="utf-8")
print(json.dumps(dict(status=result["status"], gate_counter_bits=len(counter_regs), physical_counter_bits=len(bits), ripple_cells=len(ripple), comparison_constants=[c["constant"] for c in comparisons], boot_checks=boot_checks), ensure_ascii=False))
