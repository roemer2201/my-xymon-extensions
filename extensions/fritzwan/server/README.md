# fritzwan — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
metric (`bps_down : 20000000`, `util_up : 5.0`, …). The Xymon server
turns those into RRD files and graphs via **split-NCV**. This is a
one-time setup on the Xymon server host.

Both steps are **drop-in files**: nothing in a stock Xymon config file
has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform (Debian/Ubuntu ship them ready to use).

## 1. xymonserver.d/my-xymon-extensions-fritzwan.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/my-xymon-extensions-fritzwan.cfg /etc/xymon/xymonserver.d/
```

All fritzwan metrics are plain gauges (the extension computes the
throughput itself, so no COUNTER/DERIVE handling is needed), so the
file is short:

```
TEST2RRD+=",fritzwan=ncv"
SPLITNCV_fritzwan="*:GAUGE"
GRAPHS+=",fritzwanbps,fritzwanutil"
GRAPHS_fritzwan="fritzwanbps,fritzwanutil"
```

## 2. graphs.d/my-xymon-extensions-fritzwan.cfg

Copy the graph definitions shipped next to this README:

```sh
cp graphs.d/my-xymon-extensions-fritzwan.cfg /etc/xymon/graphs.d/
```

## 3. Restart / verify

Restart the Xymon server (a restart, not a reload — on Debian/Ubuntu
the list of included drop-in files is regenerated at start). After the
second poll (the first one only primes the rate calculation), check
that RRD files appear:

```
ls $XYMONVAR/rrd/<fritzbox-host>/fritzwan,*
```

## Alerting

The column goes red when the physical WAN link is down; utilization
alerting is opt-in via `UTIL_WARN`/`UTIL_CRIT` in `fritzwan.cfg`. A
normal `alerts.cfg` rule is enough, e.g.:

```
HOST=fritz.box TEST=fritzwan
    MAIL admin@example.com COLOR=red REPEAT=4h
```
