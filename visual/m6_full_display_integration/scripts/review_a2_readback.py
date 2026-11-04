"""只读复查 A2 网表比较常量、诊断状态位和封存哈希。"""
from __future__ import annotations

import bisect
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "experiments/board_0x46_A2_work"
GATE = WORK / "td_run/check_a2/gate_netlist.v"
ROUTE = WORK / "td_run/bit_a2_final/route_netlist.v"
PREFIX = r"\u_display/u_label_store/"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def physical_comparisons(expected: list[dict]) -> list[dict]:
    """沿最终 route 的 LOGIC f 输出展开 LUT INIT，不使用源文件比较表达式。"""
    source = ROUTE.read_text(encoding="utf-8")
    newlines = [m.start() for m in re.finditer("\n", source)]
    vectors = {name.strip(): (int(high), int(low)) for high, low, name in re.findall(
        r"(?m)^  wire \[(\d+):(\d+)\] ([^;]+);", source)}

    def bits(expression: str) -> list[str]:
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

    drivers = {}
    for match in re.finditer(r"(?m)^  EG_PHY_[ML]SLICE[\s\S]*?;[^\n]*", source):
        block = match.group()
        name = re.search(r"\n    (\\\S+)\s+\(", block)
        if not name:
            continue
        body = block[name.start():]
        ports = {k: v.strip() for k, v in re.findall(r"\.(\w+)\(([^()]*)\)", body)}
        params = {k: v.strip() for k, v in re.findall(r"(?m)^    \.(\w+)\(([^()]*)\)", block[:name.start()])}
        if params.get("MODE") != '"LOGIC"' or "f" not in ports:
            continue
        outputs = bits(ports["f"])
        for lane, output in enumerate(outputs):
            if output.startswith("open_"):
                continue
            lut_names = ([f"INIT_LUT{lane}"] if "EG_PHY_MSLICE" in block else
                         [f"INIT_LUTF{lane}", f"INIT_LUTG{lane}"])
            if any(key not in params for key in lut_names):
                continue
            values = [int(re.fullmatch(r"\d+'([bh])([0-9a-fA-F]+)", params[key])[2],
                          2 if "'b" in params[key] else 16) for key in lut_names]
            if len(values) == 2 and params.get(f"LSFMUX{lane}") != '"FUNC5"':
                continue
            width = 4 if len(values) == 1 else 5
            truth = values[0] if width == 4 else values[0] | (values[1] << 16)
            inputs = []
            for pin in "abcde"[:width]:
                pair = bits(ports.get(pin, "2'b00"))
                inputs.append(pair[lane] if lane < len(pair) else "1'b0")
            drivers[output] = {"instance": name[1], "line": bisect.bisect_left(newlines, match.start()) + 1,
                               "inputs": inputs, "truth": truth, "text": block}

    @lru_cache(maxsize=None)
    def cube(net: str, wanted: int) -> tuple[tuple[str, int], ...]:
        if net not in drivers:
            return ((net, wanted),)
        cell = drivers[net]
        # 合并重复输入并折叠常量；物理 LUT 未使用的端口不应被误判为条件。
        variables = list(dict.fromkeys(n for n in cell["inputs"] if n not in ("1'b0", "1'b1")))
        table = []
        for assignment in range(1 << len(variables)):
            value = {n: (assignment >> i) & 1 for i, n in enumerate(variables)}
            value.update({"1'b0": 0, "1'b1": 1})
            index = sum(value[n] << i for i, n in enumerate(cell["inputs"]))
            table.append((cell["truth"] >> index) & 1)
        active = [i for i in range(len(variables)) if any(
            table[j] != table[j ^ (1 << i)] for j in range(len(table)))]
        hits = [j for j in range(1 << len(active)) if table[sum(((j >> k) & 1) << i for k, i in enumerate(active))] == wanted]
        if len(hits) != 1:
            raise ValueError(f"物理输出不满足单一合取条件：{net}")
        leaves = {}
        for k, i in enumerate(active):
            for leaf, bit in cube(variables[i], (hits[0] >> k) & 1):
                if leaf in leaves and leaves[leaf] != bit:
                    raise ValueError("互相矛盾的物理条件")
                leaves[leaf] = bit
        return tuple(sorted(leaves.items()))

    results = []
    for comparison in expected:
        leaves = dict(cube(comparison["output"], 1))
        assert leaves == comparison["leaves"], (comparison["output"], leaves)
        visited = {}

        def trace(net: str) -> None:
            if net not in drivers or net in visited:
                return
            visited[net] = drivers[net]
            for input_net in drivers[net]["inputs"]:
                trace(input_net)

        trace(comparison["output"])
        results.append({"output": comparison["output"], "constant": comparison["constant"],
                        "gate_route_leaves_identical": True, "cells": list(visited.values())})
    return results


def main() -> None:
    source = GATE.read_text(encoding="utf-8")
    newlines = [m.start() for m in re.finditer("\n", source)]
    luts, registers = {}, []
    for match in re.finditer(r"(?m)^  AL_MAP_\w+[\s\S]*?;[^\n]*", source):
        block = match.group()
        name = re.search(r"\n    (\\\S+)\s+\(", block)
        if not name:
            continue
        ports = {k: v.strip() for k, v in re.findall(r"\.(\w+)\(([^()]*)\)", block)}
        record = {"instance": name[1], "line": bisect.bisect_left(newlines, match.start()) + 1,
                  "ports": ports, "text": block}
        if block.startswith("  AL_MAP_LUT"):
            init = re.search(r"\.INIT\(\d+'h([\da-fA-F]+)\)", block)
            if init:
                record.update(width=int(re.search(r"AL_MAP_LUT(\d+)", block)[1]),
                              init=int(init[1], 16))
                luts[ports["o"]] = record
        elif block.startswith("  AL_MAP_SEQ"):
            registers.append(record)

    @lru_cache(maxsize=None)
    def cube(net: str, value: int) -> tuple[tuple[str, int], ...]:
        """展开恰好一个输入组合满足的 LUT；拒绝把一般布尔函数当比较器。"""
        if net not in luts:
            return ((net, value),)
        cell = luts[net]
        hits = [i for i in range(1 << cell["width"]) if ((cell["init"] >> i) & 1) == value]
        if len(hits) != 1:
            raise ValueError("不是单一合取条件")
        assignments = {}
        for i in range(cell["width"]):
            for leaf, bit in cube(cell["ports"][chr(97 + i)], (hits[0] >> i) & 1):
                if leaf in assignments and assignments[leaf] != bit:
                    raise ValueError("互相矛盾的输入")
                assignments[leaf] = bit
        return tuple(sorted(assignments.items()))

    comparisons = []
    for net, cell in luts.items():
        if not net.startswith(PREFIX + "state_reg"):
            continue
        try:
            leaves = dict(cube(net, 1))
        except ValueError:
            continue
        indices = {}
        for leaf, bit in leaves.items():
            match = re.fullmatch(re.escape(PREFIX + "watchdog") + r" \[(\d+)\]", leaf)
            if not match:
                break
            indices[int(match[1])] = bit
        else:
            if set(indices) == set(range(29)):
                value = sum(bit << index for index, bit in indices.items())
                comparisons.append({"output": net, "constant": value, "hex": hex(value),
                                    "line": cell["line"], "bits_28_to_0": "".join(str(indices[i]) for i in reversed(range(29))),
                                    "leaves": leaves})
    assert {c["constant"] for c in comparisons} == {499999, 499999999}, comparisons

    selected = [r for r in registers if re.fullmatch(
        re.escape(PREFIX) + r"(?:state_reg\[\d+\]|u_init/state_reg\[\d+\]|u_reader/state_reg\[\d+\]|u_mem/state_reg\[\d+\]|debug_snapshot_reg\[[0-3]\])",
        r["instance"])]
    state_regs = [r for r in selected if r["instance"].startswith(PREFIX + "state_reg[")]
    assert len(state_regs) == 4
    for i in range(4):
        r = next(r for r in state_regs if r["instance"] == PREFIX + f"state_reg[{i}]")
        assert r["ports"]["q"] == PREFIX + f"state [{i}]"
        snap = next(r for r in selected if r["instance"] == PREFIX + f"debug_snapshot_reg[{i}]")
        assert snap["ports"]["d"] == r["ports"]["q"]

    log = next((WORK / "td_run/synth_a2").glob("td_*.log"))
    recoded = [line for line in log.read_text(encoding="utf-8", errors="replace").splitlines()
               if "SYN-1067" in line and "u_display/u_label_store/" in line]
    assert not any("'u_display/u_label_store/state_reg'" in line for line in recoded)

    bit = ROOT / "deliverables/M6_FDI_A2_20261005_7B97635A.bit"
    assert sha(bit) == "7b97635aadd6fa4ebab8f3fc598f195cde5bafcdf6b6968bf105ac62284cd57c"
    route_comparisons = physical_comparisons(comparisons)
    boot_checks = []
    for count, expected_state in [(499998, 0), (499999, 1)]:
        known = {PREFIX + f"state [{i}]": 0 for i in range(4)}
        known.update({PREFIX + f"watchdog [{i}]": (count >> i) & 1 for i in range(29)})
        known.update({"1'b0": 0, "1'b1": 1})

        @lru_cache(maxsize=None)
        def evaluate(net: str) -> int | None:
            if net in known:
                return known[net]
            if net not in luts:
                return None
            cell = luts[net]
            inputs = [evaluate(cell["ports"][chr(97 + i)]) for i in range(cell["width"])]
            unknown = [i for i, bit in enumerate(inputs) if bit is None]
            outputs = set()
            for assignment in range(1 << len(unknown)):
                index = sum((bit or 0) << i for i, bit in enumerate(inputs))
                index |= sum(((assignment >> k) & 1) << i for k, i in enumerate(unknown))
                outputs.add((cell["init"] >> index) & 1)
            return next(iter(outputs)) if len(outputs) == 1 else None

        next_bits = [evaluate(next(r for r in state_regs if r["instance"] == PREFIX + f"state_reg[{i}]")["ports"]["d"])
                     for i in range(4)]
        assert next_bits == [(expected_state >> i) & 1 for i in range(4)], next_bits
        boot_checks.append({"current_state": 0, "watchdog": count,
                            "next_state": expected_state, "other_inputs": "unknown, conservatively propagated"})
    boot_output = ROOT / "doc/output/A2_PROBE_GATE_BOOT_CHECK_20261006.json"
    boot_text = json.dumps({"gate_sha256": sha(GATE), "checks": boot_checks}, ensure_ascii=False, indent=2) + "\n"
    if boot_output.exists():
        assert boot_output.read_text(encoding="utf-8") == boot_text
    else:
        boot_output.write_text(boot_text, encoding="utf-8")
    evidence = {"status": "PASS_STATIC_REVIEW_HARDWARE_READBACK_BANK_UNCONFIRMED",
                "bit": str(bit), "bit_sha256": sha(bit), "gate": str(GATE), "gate_sha256": sha(GATE),
                "route": str(ROUTE), "route_sha256": sha(ROUTE), "comparisons": comparisons,
                "route_comparisons": route_comparisons,
                "registers": selected, "loader_recoded_log_lines": recoded,
                "limits": "LUT INIT 静态展开及寄存器直连证据；不证明真卡、时钟/复位或板上实际开关电平。"}
    output = ROOT / "doc/output/A2_PROBE_STATIC_REVIEW_FINAL_20261006.json"
    evidence_text = json.dumps(evidence, ensure_ascii=False, indent=2) + "\n"
    if output.exists():
        assert output.read_text(encoding="utf-8") == evidence_text, f"既有证据不符，禁止覆盖：{output}"
    else:
        output.write_text(evidence_text, encoding="utf-8")
    print(json.dumps({"output": str(output), "comparisons": [{k: c[k] for k in ("output", "constant", "hex")} for c in comparisons],
                      "boot_checks": boot_checks,
                      "state_register_count": len(state_regs), "recoded": recoded}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
