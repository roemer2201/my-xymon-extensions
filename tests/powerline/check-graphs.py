#!/usr/bin/env python3
"""Optional graph smoke test: stdlib Python 3 and rrdtool, no Xymon daemon.

Creates temporary GAUGE RRDs, verifies U is stored as unknown and renders
every shipped graph using Xymon's filename/placeholder conventions.
Usage: python3 tests/powerline/check-graphs.py
RRDTOOL can select a non-default binary. No persistent files or PLC access.
"""

import math
import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
RRD = os.environ.get("RRDTOOL", "rrdtool")
START = 1_650_000_000
PAIR = "af0b01484c53c_pe8df701d65a6_"
KEYS = [
    "tx_phy_mbps", "rx_phy_mbps", "tx_pb_interval_pct",
    "rx_pb_interval_pct", "tx_pb_pass_per_second", "rx_pb_fail_per_second",
    "tx_mpdu_ack_per_second", "tx_mpdu_fail_per_second",
    "tx_mpdu_collision_per_second", "rx_slot0_phy_mbps",
    "rx_slot0_pb_interval_pct", "rx_slot0_ber_interval_pct",
    "rx_all_ber_interval_pct", "rx_all_fec_interval_pct",
    "rx_all_fec_reported_pct", "tx_pb_reported_pct",
    "tx_mpdu_interval_pct", "tx_mpdu_ack", "tx_mpdu_fail",
    "tx_mpdu_collision", "rx_slot0_ber_pass", "rx_slot0_pb_pass",
]


def rrd(*args):
    """Run real RRDtool and retain actionable stderr on failure."""
    result = subprocess.run([RRD, *map(str, args)], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout


def check():
    """Validate patterns, standard RRD unknowns and all graph command lines."""
    source = ROOT / "extensions/powerline/server/graphs.d/powerline.cfg"
    groups = {}
    for line in source.read_text(encoding="ascii").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            name = line[1:-1]
            groups[name] = []
        else:
            groups[name].append(line)
    with tempfile.TemporaryDirectory(prefix="powerline-graphs-") as directory:
        work = Path(directory)
        keys = [PAIR + key for key in KEYS] + ["af0b01484c53c_pself_present"]
        files = []
        for key in keys:
            filename = work / ("powerline," + key + ".rrd")
            rrd("create", filename, "--start", START - 300, "--step", 300,
                "DS:value:GAUGE:600:0:U", "RRA:AVERAGE:0.5:1:24")
            rrd("update", filename, f"{START}:10", f"{START + 300}:U",
                f"{START + 600}:20")
            files.append(filename)
        fetched = rrd("fetch", files[0], "AVERAGE", "--start", START,
                      "--end", START + 600)
        rows = {int(t): float(v) for t, v in re.findall(r"^(\d+):\s+(\S+)",
                                                       fetched, re.MULTILINE)}
        assert math.isnan(rows[START + 300]), fetched
        assert rows[START + 600] == 20, fetched
        matched = set()
        for name, lines in groups.items():
            args = ["graph", work / f"{name}.png", "--start", START,
                    "--end", START + 600, "--width", 600, "--height", 180]
            pattern = None
            templates = []
            for line in lines:
                if line.startswith("FNPATTERN "):
                    pattern = re.compile(line.split(" ", 1)[1])
                elif line.startswith("TITLE "):
                    args.extend(["--title", line[6:]])
                elif line.startswith("YAXIS "):
                    args.extend(["--vertical-label", line[6:]])
                elif line.startswith("-"):
                    args.extend(line.split())
                else:
                    templates.append(line)
            count = 0
            for filename in files:
                match = pattern.search(filename.name)
                if not match:
                    continue
                matched.add(filename)
                for template in templates:
                    args.append(template.replace("@RRDIDX@", str(count))
                                .replace("@RRDFN@", str(filename))
                                .replace("@RRDPARAM@", match.group(1))
                                .replace("@COLOR@", "008000"))
                count += 1
            assert count, f"{name}: pattern matches no representative metric"
            rrd(*args)
            print(f"ok: rendered {name} ({count} series)")
        assert set(files) == matched, "Representative metrics missing from graphs"
        print("ok: RRD stores missing samples as unknown, not zero")


if __name__ == "__main__":
    check()
