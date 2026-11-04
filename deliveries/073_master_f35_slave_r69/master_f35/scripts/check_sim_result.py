"""校验本次仿真结果；未运行、超时、编译失败和旧日志均不能作为通过。"""
import argparse
import json
import re
from pathlib import Path


def check(text, exit_code):
    reasons = []
    if exit_code != 0:
        reasons.append(f"process_exit={exit_code}")
    verdicts = re.findall(r"^RESULT (PASS|FAIL)\b.*$", text, re.M)
    if verdicts != ["PASS"]:
        reasons.append(f"expected_one_pass_got={verdicts}")
    reset_window = False
    reset_diagnostics = []
    for line in text.splitlines():
        if line.startswith("PHASE KEY1_RESET_BEGIN"):
            reset_window = True
        elif line.startswith("PHASE KEY1_REINITIALIZED"):
            reset_window = False
        elif re.search(r"(^ERROR\b|CARD ERROR|MODEL ERROR|%Error|Assertion failed|\$fatal)", line):
            allowed_reset = reset_window and (
                line == "CARD ERROR: CLK high < 7ns" or
                re.fullmatch(r"MODEL ERROR @\d+ now=\d+: refresh interval exceeded", line)
            )
            if allowed_reset:
                reset_diagnostics.append(line)
            else:
                reasons.append(line)
    if reset_window:
        reasons.append("KEY1 reinitialization did not complete")
    if sum("CARD ERROR" in x for x in reset_diagnostics) > 1:
        reasons.append("repeated clock-width diagnostics during KEY1")
    if sum("MODEL ERROR" in x for x in reset_diagnostics) > 1:
        reasons.append("repeated refresh diagnostics during KEY1")
    return {
        "passed": not reasons,
        "status": "FAIL" if reasons else
                  "PASS_WITH_KEY1_DIAGNOSTICS" if reset_diagnostics else "PASS",
        "reasons": reasons,
        "key1_reset_diagnostics": reset_diagnostics,
        "scope": "KEY1 destroys the previous media/memory session; soft media switches receive no exception",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--exit-code", type=int, required=True)
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()
    result = check(args.log.read_text(encoding="utf-8", errors="replace"), args.exit_code)
    args.json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(result["status"])
    for reason in result["reasons"][:12]:
        print(reason)
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
