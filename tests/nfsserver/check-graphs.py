#!/usr/bin/env python3
"""Optional graph smoke test: stdlib Python 3, rrdtool and the collector.

Runs nfsserver.sh twice against a fixture /proc tree that offers every
optional interface, creates the RRDs from the DS lines of its trends
message, checks that every graph finds its files and data sources and
that every sent data source is drawn, and renders every shipped graph
using Xymon's filename/placeholder conventions.
Usage: python3 tests/nfsserver/check-graphs.py
RRDTOOL can select a non-default binary. No persistent files, no NFS.
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
MACHINE = "graphtest"


def rrd(*args, cwd=None):
    """Run real RRDtool and retain actionable stderr on failure."""
    result = subprocess.run([RRD, *map(str, args)], text=True,
                            capture_output=True, cwd=cwd)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="ascii")


def fixtures(work, calls):
    """A kernel nfsd with RDMA, file cache and two exports in use."""
    proc = work / "proc"
    write(proc / "sys/kernel/random/boot_id", "graph-boot\n")
    write(proc / "fs/nfsd/portlist", "tcp 2049\ntcp 2049\nrdma 20049\n")
    proc3 = " ".join(str(calls if i in (1, 3, 6, 7, 16, 17, 21) else 0)
                     for i in range(22))
    proc4 = " ".join(str(calls if i in (4, 5, 9, 15, 18, 25, 26, 38) else 0)
                     for i in range(76))
    write(proc / "net/rpc/nfsd",
          f"rc 0 {calls} 0\nfh 1 0 0 0 0\nio {calls * 4096} {calls * 8192}\n"
          "th 64 0 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000\n"
          f"rpc {calls} 1 1 0 0\nproc3 22 {proc3}\nproc4ops 76 {proc4}\n")
    for counter in ("recv", "read", "write", "sq_starve"):
        write(proc / f"sys/sunrpc/svc_rdma/rdma_stat_{counter}", f"{calls}\n")
    write(proc / "fs/nfsd/reply_cache_stats",
          "max entries:           221120\nnum entries:           4535\n"
          "hash buckets:          4096\nmem usage:             1201472\n")
    write(proc / "fs/nfsd/filecache",
          "total inodes:  120\nhash buckets:  1024\nlru entries:   80\n")
    write(proc / "fs/nfsd/export_stats",
          "# Version 1.1\n# Path Client Start-time\n#\tStats\n"
          f"/home\t*\t92\n\tfh_stale: 0\n\tio_read: {calls * 1048576}\n"
          f"\tio_write: {calls * 524288}\n\n"
          f"/work\\040dir\t192.0.2.0/24\t93\n\tfh_stale: 0\n"
          f"\tio_read: {calls * 2048}\n\tio_write: {calls * 1024}\n\n")
    write(work / "etab", "/home\t*(rw,sync)\n/work\\040dir\t192.0.2.0/24(rw)\n")
    write(work / "etc/exports", "/home *(rw)\n")
    write(work / "monitor.cfg", "")


def collect(work):
    """One collector run; returns {rrd file: {ds: value}} of its trends."""
    env = {key: value for key, value in os.environ.items()
           if key not in ("XYMON", "XYMSRV")}
    env.update(LC_ALL="C", MACHINE=MACHINE, XYMONTMP=str(work),
               NFSSERVER_PROC=str(work / "proc"),
               NFSSERVER_ETC=str(work / "etc"),
               NFSSERVER_ETAB=str(work / "etab"),
               NFSSERVER_CFG=str(work / "monitor.cfg"),
               NFSSERVER_REQUIRED_LISTENERS="tcp:2049 rdma:20049",
               NFSSERVER_GLOBAL_BYTES="yes")
    result = subprocess.run(
        ["sh", str(ROOT / "extensions/nfsserver/nfsserver.sh")],
        env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert re.match(rf"^status {MACHINE}\.nfsserver green ", result.stdout), \
        result.stdout
    trends = result.stdout.split(f"data {MACHINE}.trends\n", 1)
    assert len(trends) == 2, result.stdout
    files = {}
    current = None
    for line in trends[1].splitlines():
        match = re.fullmatch(r"\[(.+\.rrd)\]", line)
        if match:
            current = files.setdefault(match.group(1), {})
            continue
        match = re.fullmatch(r"DS:(\w+):GAUGE:600:0:U (\S+)", line)
        assert match and current is not None, f"unexpected trends line: {line}"
        current[match.group(1)] = match.group(2)
    return files


def age(work, seconds):
    """Move the stored sample back in time, as a real poll interval would."""
    state = work / f"nfsserver-{MACHINE}" / "previous"
    lines = state.read_text(encoding="ascii").splitlines()
    clock, now, boot = lines[0].split()
    lines[0] = f"{clock} {int(now) - seconds} {boot}"
    state.write_text("\n".join(lines) + "\n", encoding="ascii")


def graphs():
    source = ROOT / "extensions/nfsserver/server/graphs.d/nfsserver.cfg"
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
    return groups


def check():
    with tempfile.TemporaryDirectory(prefix="nfsserver-graphs-") as directory:
        work = Path(directory)
        fixtures(work, 1000)
        first = collect(work)
        age(work, 300)
        fixtures(work, 4000)
        second = collect(work)
        assert first.keys() == second.keys(), (first.keys(), second.keys())
        assert all(v == "U" for v in first["nfsserver.rrd"].values()), first
        assert all(v != "U" for f in second.values() for v in f.values()), second

        rrds = work / "rrd"
        rrds.mkdir()
        for filename, values in second.items():
            rrd("create", rrds / filename, "--start", START - 300, "--step", 300,
                *[f"DS:{ds}:GAUGE:600:0:U" for ds in values],
                "RRA:AVERAGE:0.5:1:24")
            for offset, sample in ((0, values), (300, first[filename]),
                                   (600, values)):
                rrd("update", rrds / filename, f"{START + offset}:" +
                    ":".join(sample[ds] for ds in values))
        fetched = rrd("fetch", rrds / "nfsserver.rrd", "AVERAGE", "--start",
                      START, "--end", START + 600)
        rows = {int(t): v for t, v in re.findall(r"^(\d+):\s+(\S+)", fetched,
                                                 re.MULTILINE)}
        assert math.isnan(float(rows[START + 300])), fetched
        assert not math.isnan(float(rows[START + 600])), fetched

        drawn = set()
        for name, lines in graphs().items():
            args = ["graph", f"{name}.png", "--start", START, "--end",
                    START + 600, "--width", 600, "--height", 180]
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
            if pattern:
                matched = [(f, pattern.search(f)) for f in sorted(second)]
                matched = [(f, m.group(1)) for f, m in matched if m]
            else:
                matched = [(None, "")]
            assert matched, f"{name}: pattern matches no file the collector sent"
            for index, (filename, param) in enumerate(matched):
                for template in templates:
                    line = (template.replace("@RRDIDX@", str(index))
                            .replace("@RRDFN@", filename or "")
                            .replace("@RRDPARAM@", param)
                            .replace("@COLOR@", "008000"))
                    match = re.match(r"DEF:\w+=([^:]+):(\w+):", line)
                    if match:
                        rrdfile, ds = match.groups()
                        assert ds in second.get(rrdfile, {}), \
                            f"{name}: {rrdfile} has no data source {ds}"
                        drawn.add((rrdfile, ds))
                    args.append(line)
            # Xymon's showgraph runs rrdtool in the host's RRD directory.
            rrd(*args, cwd=rrds)
            print(f"ok: rendered {name} ({len(matched)} file(s))")
        sent = {(f, ds) for f, values in second.items() for ds in values}
        assert sent == drawn, f"sent but never drawn: {sorted(sent - drawn)}"
        print("ok: every data source the collector sends is drawn")
        print("ok: RRD stores the collector's first-poll U as unknown")


if __name__ == "__main__":
    check()
