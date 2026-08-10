# if_link — network interface link state changes

Xymon client extension that counts the **link state transitions**
(carrier changes) of a host's network interfaces and reports them in
one status column with a `data` message for RRD graphing. A short
cable outage — link down followed by link up — counts as **two**
changes.

- **Column:** `if_link` (override with `IF_LINK_COLUMN`). The name
  follows the devmon convention for interface tests (`if_err`,
  `if_stat`, …).
- **Platforms:** Linux only (see [Why Linux only](#why-linux-only)).
  Written for OpenWrt/TurrisOS routers and access points running
  through the standalone runner, but works on any Linux host. Other
  platforms report `clear`.
- **Colors:** `green` by default, no matter how much a port flaps —
  what counts as "too much" depends on the port. Thresholds are opt-in
  (`IF_LINK_YELLOW`/`IF_LINK_RED`/`IF_LINK_THRESHOLDS`).

## Where the numbers come from

`/sys/class/net/<if>/carrier_changes` — a counter the kernel itself
increments on **every** carrier transition. Fallback for kernels that
lack it: the sum of `carrier_up_count` and `carrier_down_count`.

This matters: comparing the current link state between two polls would
only ever see flaps that happen to straddle a poll boundary. A port
that goes down and comes back within three seconds is invisible to
that approach and fully visible here.

## Metrics (NCV names)

Metric names are keyed by the sanitized interface name: `lan4` becomes
`changes_lan4`, `phy0-ap0` becomes `changes_phy0_ap0`.

| Name | Unit | Meaning |
|------|------|---------|
| `changes_<if>` | count per poll interval | link state transitions since the previous poll |

The value is a plain gauge computed by the extension from a state file
(`$XYMONTMP/if_link.<host>.state`) between two runs — no background
process, no COUNTER/DERIVE handling on the server. The first poll only
primes the state file; values appear with the second poll.

Because the metric is "changes since the previous poll", it is only
comparable across time when the poll interval is constant — keep the
`INTERVAL` (or the cron schedule of the standalone runner) stable.

The extension always sends whole numbers, but the values **stored** in
the RRD are fractional: RRDtool splits every value across two slots of
its epoch-aligned 5-minute grid, and Xymon's default archives dilute a
flap further over longer time ranges. The server setup deals with the
second part — see
[Fractional values in the graph](#fractional-values-in-the-graph).

The cumulative counter, the current link state, speed/duplex and the
bridge an interface belongs to are shown in the status text only. That
whole block is fenced with `<!-- ncv_skipstart -->` /
`<!-- ncv_skipend -->`, because the server's NCV parser treats `=`
like `:` and would otherwise turn every `link=up` into an RRD dataset.

## Which interfaces are monitored

Auto-detection keeps the **physical Ethernet ports**: `ARPHRD_ETHER`
devices (`type` = 1) that have a `device` link in sysfs. On a Turris
Omnia that is `eth0`–`eth2` plus the DSA switch ports `lan0`–`lan4`;
on a Zyxel NWA50AX Pro just `eth0`.

Left out by default, each for a reason:

| Kind | Example | Why |
|------|---------|-----|
| loopback, tunnels | `lo`, `sit0`, `ip6tnl0` | not `ARPHRD_ETHER`, no cable |
| bridges | `br-lan`, `docker0` | carrier just follows the member ports |
| veth pairs | `vethpVH4oZ` | come and go with containers — one new RRD file per container start |
| wireless | `phy0-ap0` | carrier only changes when hostapd restarts the interface; the `wifi` extension covers the radios |

Adjust with `IF_LINK_INTERFACES` (explicit list, glob patterns),
`IF_LINK_EXCLUDE`, `IF_LINK_WIRELESS` and `IF_LINK_VIRTUAL` — see the
shipped `if_link.cfg`.

An interface that is **administratively down** (`ip link set … down`,
e.g. an unused SFP port) cannot flap: reading its `carrier` attribute
fails, so it is shown as `link=admin-down` with a `&clear` marker and
never triggers a threshold.

## Thresholds

Off by default. `IF_LINK_YELLOW` / `IF_LINK_RED` set a global limit on
the number of changes per poll interval; `IF_LINK_THRESHOLDS` holds
per-interface `"<glob>:<yellow>:<red>"` entries, first match wins:

```sh
IF_LINK_YELLOW="2"
IF_LINK_THRESHOLDS="lan4:2:6 lan0::"
```

Remember the factor two: one short outage is two changes, so `2` means
"one flap per interval is enough".

## Caveats

- A **counter reset** (reboot, interface re-created) makes the delta
  negative. The metric is skipped for that one poll — the status shows
  `changes=n/a(counter reset)` — and the re-primed state takes over
  with the next one. No negative value ever reaches the RRD.
- A **new interface** has no previous value; its first poll shows
  `changes=n/a(first poll)`.
- Interfaces that disappear simply drop out of the state file — the
  RRD files created for them stay behind on the server until you
  remove them.
- Whether a driver counts a link change at all is up to the driver.
  All ports observed so far (mvebu/DSA `mv88e6xxx`, mediatek/filogic)
  count correctly; a port stuck at `total=0` while the cable is
  clearly flapping is a driver limitation, not an extension bug.

## Fractional values in the graph

A graph showing `0.4` link changes is not a bug in this extension — the
`data` message only ever contains integers. RRDtool produces the
fractions, in two independent ways:

- **Step normalization**: RRDtool aligns its 5-minute grid to the epoch,
  not to the poll times, so a poll sitting at a fixed offset inside that
  grid has every value split across two slots — a flap of 2 becomes
  1.33 + 0.67 at an offset of 100 s. Regular polling does not help; this
  is a constant phase offset, not jitter, and no dataset type avoids it.
- **Archive consolidation**: Xymon's default archives consolidate with
  AVERAGE, so a graph longer than 48 hours divides the flap by the
  consolidation factor of the view — the stored 1.33 is drawn as 0.39
  over 5 days and 0.07 over 40 days.

The first one is inherent to RRDtool and cannot be turned off. The
second is what the server setup shipped here fixes:
`server/rrddefinitions.d/if_link.cfg` adds MAX archives alongside the
default AVERAGE ones and the graph draws from MAX, so a flap keeps the
same visible height in every time range. For an exact number the graph
prints `(total)`, the per-poll counts integrated back into an event
count over the shown window.

Both are explained in detail, with measured figures, in
[`server/README.md`](server/README.md) — including the one-time removal
of existing RRD files that the new archives require.

## Why Linux only

No other platform this repository supports keeps a kernel-side link
change counter. FreeBSD only exposes the *current* state
(`ifconfig … status: active`), so a FreeBSD implementation would have
to compare polls and would silently miss every flap shorter than the
poll interval — a monitoring result that looks fine and is wrong. The
extension therefore reports `clear` there instead, with a hint in the
status text.

## Configuration

See the shipped `if_link.cfg` (installed to `$XYMONHOME/etc/if_link.cfg`);
every setting can also come from the environment, the config file
wins. Defaults work out of the box.

## Graphing (Xymon server setup)

See [`server/README.md`](server/README.md) — split-NCV setup, the RRD
archive definition in
[`server/rrddefinitions.d/if_link.cfg`](server/rrddefinitions.d/if_link.cfg)
and the graph definition in
[`server/graphs.d/if_link.cfg`](server/graphs.d/if_link.cfg). The two
belong together: the graph draws from the MAX archives that the archive
definition adds.

## Packaging notes

- The `clientlaunch.d` snippet ships **enabled**: the extension needs nothing
  but `/sys/class/net`, which every Linux host has, and it stays green
  until thresholds are configured. On a server it watches the NICs
  (`eno1`, `enp3s0`, …), on a router the individual switch ports.
- On FreeBSD the column is permanently `clear` (see
  [Why Linux only](#why-linux-only)) — comment the `[if_link]` block
  in `clientlaunch.d/if_link.cfg` out there if you would rather not see it.
- On OpenWrt/TurrisOS the extension is part of the default `TESTS`
  list of the standalone runner.
