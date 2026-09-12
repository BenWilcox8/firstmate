#!/usr/bin/env python3
"""Reproduce the public serial-lane schedule and compare its declared bounds."""
import json
import re
import subprocess
from pathlib import Path

root = Path("/home/ben/.no-mistakes-upstream-r1/worktrees/693934b1db22/01M2B7M1QR4P42Y4DF4DY7REGF")
runner = root / "bin/fm-test-run.sh"
docs = (root / "docs/fm-test-portable-shards.md").read_text(encoding="utf-8")
source = runner.read_text(encoding="utf-8")

# This is the runner's declarative timing table, consumed by its LPT lane selector.
match = re.search(r"portable_serial_weight_hints\(\) \{\n  cat <<'EOF'\n(.*?)\nEOF", source, re.S)
assert match, "could not locate runner timing table"
weights = {}
for line in match.group(1).splitlines():
    path, weight = line.split()
    weights[path] = int(weight)

lanes = {}
for shard in range(1, 7):
    result = subprocess.run(
        [str(runner), "--list", "--lane", f"portable-serial-{shard}of6"],
        cwd=root, text=True, capture_output=True, check=True,
    )
    paths = [line for line in result.stdout.splitlines() if line]
    assert paths, f"lane {shard} is empty"
    assert all(path in weights for path in paths), f"lane {shard} has an unhinted path"
    lanes[f"portable-serial-{shard}of6"] = {
        "script_count": len(paths),
        "retained_max_ms": sum(weights[path] for path in paths),
        "hint_plus_60000ms_allowance": sum(weights[path] for path in paths) + 60000,
        "scripts": paths,
    }

coverage = subprocess.run([str(runner), "--check-coverage"], cwd=root, text=True, capture_output=True, check=True)
serial = subprocess.run([str(runner), "--list", "--lane", "portable-serial"], cwd=root, text=True, capture_output=True, check=True)
covered = [path for lane in lanes.values() for path in lane["scripts"]]
serial_paths = [line for line in serial.stdout.splitlines() if line]
assert len(covered) == len(set(covered)), "serial shards overlap"
assert set(covered) == set(serial_paths), "serial shards do not exactly cover the serial lane"
assert sum(weights.values()) == 6053782, "timing-table total differs from frozen measured inputs"
assert max(lane["retained_max_ms"] for lane in lanes.values()) == 1008996, "largest retained-max sum changed"
assert max(lane["hint_plus_60000ms_allowance"] for lane in lanes.values()) == 1068996, "largest allowance-inclusive estimate changed"
assert max(lane["hint_plus_60000ms_allowance"] for lane in lanes.values()) < 1200000, "serial estimate exceeds CI bound"
assert "The shipped hints total 6053782 ms" in docs
assert "The maximum retained sum plus that allowance is 1068996 ms, leaving 131004 ms" in docs
assert "| `portable-serial-2of6` | 30 | 1008996 ms | 1068996 ms |" in docs

report = {
    "result": "pass",
    "public_runner_coverage": coverage.stdout.strip(),
    "serial_scripts": len(serial_paths),
    "timing_table_total_ms": sum(weights.values()),
    "ci_job_bound_ms": 1200000,
    "setup_allowance_ms": 60000,
    "largest_retained_max_ms": max(lane["retained_max_ms"] for lane in lanes.values()),
    "largest_estimate_ms": max(lane["hint_plus_60000ms_allowance"] for lane in lanes.values()),
    "margin_ms": 1200000 - max(lane["hint_plus_60000ms_allowance"] for lane in lanes.values()),
    "lanes": lanes,
}
print(json.dumps(report, indent=2, sort_keys=True))
