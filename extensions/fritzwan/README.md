# fritzwan — AVM FRITZ!Box WAN throughput monitoring

Polls an AVM FRITZ!Box for its WAN interface traffic counters and
physical link state and reports the Xymon column **`fritzwan`**,
attached to the box's own host entry.

Like [fritzdsl](../fritzdsl/), this is a **poller**: it runs on the
Xymon server itself (or any host that can reach the box) — nothing is
installed on the FRITZ!Box. Both extensions are independent; use
either or both.

## How the throughput is measured

The box exposes its WAN byte counters twice:

- **UPnP/IGD** (`GetAddonInfos` on `/igdupnp/control/WANCommonIFC1`):
  includes AVM's **64-bit counters** and needs **no login**, but
  requires *Transmit status information over UPnP* to be enabled
  (Home Network > Network > Network Settings).
- **TR-064** (`WANCommonInterfaceConfig:1`): authenticated, but the
  counters are **32-bit** and wrap every 4 GiB — at 100 Mbit/s that
  is every ~6 minutes.

The extension prefers the 64-bit UPnP counters and falls back to the
TR-064 counters (correcting a single 32-bit wrap per interval). The
throughput is computed as the **average rate since the previous
poll** from a state file in `$XYMONTMP` and reported as plain GAUGE
values, so the RRD side never has to deal with counter wraps at all.
The physical link state and the Layer-1 capacity come from
`GetCommonLinkProperties`.

## What it reports

Status color:

| Condition | Color |
|-----------|-------|
| Physical WAN link not `Up` | red |
| Box unreachable / request failed | red |
| Utilization above `UTIL_CRIT`/`UTIL_WARN` (disabled by default) | red / yellow |
| TR-064 authentication failed | yellow |
| `curl` missing, or required service disabled on the box | clear |

Metrics (sent as a `data` message for RRD graphing, see
[server/README.md](server/README.md)):

| Variable | Meaning | Unit | RRD type |
|----------|---------|------|----------|
| `bps_down`, `bps_up` | throughput, averaged over the poll interval | bit/s | GAUGE |
| `maxbps_down`, `maxbps_up` | Layer-1 link capacity | bit/s | GAUGE |
| `util_down`, `util_up` | utilization of the link capacity | % | GAUGE |

On the very first poll (no state yet) only the capacity is reported;
the rates appear from the second poll on.

## Setup

1. **On the FRITZ!Box**, either:
   - enable *Transmit status information over UPnP* (for `MODE=igd`,
     no credentials needed), and/or
   - enable TR-064 (*Allow access for applications*) and create a
     dedicated user with the *FRITZ!Box settings* permission (for
     `MODE=auto`/`tr064`).
2. **Configure** `$XYMONHOME/etc/fritzwan.cfg` on the polling host:
   set `FRITZ_USER`/`FRITZ_PASSWORD`, or `MODE="igd"`; set
   `FRITZ_HOST`/`REPORTHOST` if the box is not reachable as
   `fritz.box`. `chmod 600` the file.
3. **Add the box to `hosts.cfg`** on the Xymon server (same entry the
   `fritzdsl` column uses, if both extensions are active).
4. **Enable the task**: the shipped `clientlaunch.d/fritzwan.cfg` snippet is
   `DISABLED` by default — remove that line after configuring, then
   restart the Xymon client on the polling host.
5. **Server-side RRD/graph setup**: see [server/README.md](server/README.md).

A quick manual test (prints the report to stdout when `$XYMON` is not
set):

```sh
XYMONHOME=/usr/lib/xymon/client ./fritzwan.sh
```

## Platform notes

- Requires `curl` (reports `clear` without it). Runs on every target
  platform of this repository, including the `standalone/` runner —
  but the natural place is the Xymon server.
- Only one FRITZ!Box per config file. To monitor several boxes, run
  the script once per box with `FRITZWAN_CFG=<file>` pointing to a
  separate config (each with its own `REPORTHOST`).
- Works for any WAN type the box reports (DSL, cable, fiber, LTE);
  on non-DSL boxes this is the natural companion instead of
  `fritzdsl`.
- With `MODE=tr064` (32-bit counters) fast lines can wrap the counter
  more than once per interval, which is undetectable and yields wrong
  rates — prefer the UPnP 64-bit counters there.
