# xymonext — what the client extensions cost this host

Measures the extensions of this repository while they run and reports
the result in one column:

| Metric | Meaning |
|--------|---------|
| wall | wall clock time of a single run, in seconds |
| cpu | CPU time (user + sys) of the extension **and every process it starts**, in seconds |
| bytes | bytes the extension sent to the Xymon server in that run |
| msgs | number of messages it sent (status, data, …) |

- **Column:** `xymonext`
- **Config:** `$XYMONHOME/etc/xymonext.cfg` (see the shipped
  `xymonext.cfg`; every setting also works as an environment variable,
  the file wins)
- **Platforms:** Linux (incl. OpenWrt/TurrisOS with BusyBox) and
  FreeBSD; no external tool is required

## How it works

`xymonext.sh` is a wrapper, not a test of its own: it is called with
the name of the extension to run.

```
xymonext.sh smart        # runs $XYMONHOME/ext/smart.sh and measures it
```

The clientlaunch.d snippets shipped with the packages already do that
(`CMD $XYMONCLIENTHOME/ext/xymonext.sh smart`), and the standalone
runner `xymon-run.sh` calls the wrapper on its own when it is
installed. The measured extension runs completely unchanged: same
environment, same arguments, same stdout/stderr, and its exit code is
passed back to the caller.

Measuring is switched off with `XYMONEXT_ENABLE="no"`. The wrapper
then `exec`s the extension immediately, which leaves no measurable
overhead at all.

### Where the numbers come from

- **CPU time** — the POSIX shell builtin `times`, whose second line
  carries the user and system time of all reaped children. It is read
  once directly before and once directly after the run, and the
  difference is the cost of that extension. Everything the extension
  starts (awk, sed, smartctl, curl, …) is included, because the shell
  accounts for the whole process tree. No external tool is needed —
  which matters, since `/usr/bin/time` is not installed by default on
  Ubuntu or Rocky, and `time` is not a builtin in dash or BusyBox ash.
- **Wall clock time** — `/proc/uptime` on Linux and OpenWrt (10 ms
  resolution and no process fork at all); on FreeBSD, which has no
  `/proc/uptime`, `/usr/bin/time -p` from the base system; and
  `date +%s` as a last resort, with 1 s resolution. The status message
  names the source that was used on the host; `XYMONEXT_WALLSRC` pins
  it to one of `proc`, `time` or `date` when you want to test a
  specific path.
- **Bytes** — while an extension runs, `$XYMON` points at
  `xymonext-send.sh`, which records the size of each message and then
  hands it to the real Xymon client via `exec` (so the shim leaves no
  process of its own behind). Set `XYMONEXT_COUNT_BYTES="no"` to leave
  the transport untouched; the traffic is then not reported.

### Why the status shows every test

Each measured extension writes its last result into
`$XYMONTMP/xymonext.d/<extension>` and every run rebuilds the full
table from that directory. All extensions report into the same column,
so a message containing only the test that has just run would make the
column flip back and forth between tests scheduled at different
intervals. Entries that have not been refreshed within
`XYMONEXT_MAXAGE` (default 2 h) drop out of the table.

Example status message:

```
status host.xymonext green Mon Aug 10 12:00:03 2026 - xymonext: smart took 0.42s wall, 0.21s cpu, sent 1132 bytes

&green smart      wall   0.42s  cpu   0.21s  msgs   1  bytes    1132  (0s ago)
&green temp       wall   0.06s  cpu   0.04s  msgs   2  bytes     903  (4m ago)
&green if_link    wall   0.03s  cpu   0.02s  msgs   2  bytes     512  (4m ago)

3 extension(s) measured; totals of the runs above: cpu 0.27s, 2.5 kB sent.
Wall clock source on this host is /proc/uptime (10 ms resolution).
Bytes sent to the Xymon server are counted at the Xymon transport.
Thresholds per run (wall clock): yellow at/above 30s, red at/above 60s.
```

## Thresholds

The wall clock thresholds (`XYMONEXT_WALL_WARN` / `XYMONEXT_WALL_CRIT`,
default 30/60 s) are a hang detector: a `smartctl` waiting on a
spun-down disk or a FRITZ!Box poll running into a timeout shows up
here long before the extension's own column goes purple. A non-zero
exit code of a measured extension turns the column yellow as well
(`XYMONEXT_RC_WARN="no"` switches that off). Set both thresholds to 0
to keep the column purely informational.

## Cost of the measurement itself

Per measured run: one additional `sh` process (the wrapper) and a
handful of short `awk`/`date` calls for the formatting — in the order
of 10 ms on a Turris Omnia, less on a server. The byte counting shim
costs nothing extra because it `exec`s the real client. On the wire
the instrumentation adds one status and one data message per run,
roughly 0.5–1 kB.

Two known and deliberate inaccuracies:

- The shim runs as a child of the measured extension, so its (tiny)
  CPU time is counted as part of that extension.
- The wrapper's own report is not counted in any extension's `bytes`.

## Server side

The graphs need a one-time setup on the Xymon server — see
[`server/README.md`](server/README.md) and the graph definitions in
[`server/graphs.d/my-xymon-extensions-xymonext.cfg`](server/graphs.d/xymonext.cfg).

## Notes

- The state directory (`$XYMONTMP/xymonext.d`) can be deleted at any
  time; it is rebuilt on the next run. On OpenWrt it lives in the RAM
  disk and is empty again after a reboot, which only means the table
  fills up again test by test.
- `xymonext.sh` and `xymonext-send.sh` are infrastructure, not tests:
  the standalone runner skips them when it runs "all" extensions, and
  they must not be listed in `TESTS`.
