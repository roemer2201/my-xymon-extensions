# wifi — Wi-Fi access point metadata

Xymon client extension that collects Wi-Fi metadata from a Linux
access point — client counts, channel utilization, airtime,
throughput, TX retries and noise floor — and reports them in one
status column with a `data` message for RRD graphing.

- **Column:** `wifi` (override with `WIFI_COLUMN`)
- **Platforms:** Linux with `iw` (nl80211). Written for
  OpenWrt/TurrisOS access points via the standalone runner, where
  `ubus`/hostapd and `iwinfo` add client details. Hosts without `iw`
  or without AP-mode interfaces (e.g. FreeBSD, wired-only routers)
  report `clear`.
- **Colors:** purely informational — `green` whenever at least one
  AP-mode interface exists, `clear` otherwise. No yellow/red
  thresholds; use the graphs.

## Metrics (NCV names)

Metric names are keyed by the sanitized interface or radio name:
`phy0-ap0` becomes `phy0_ap0`, radio `phy#0` becomes `phy0`.

| Name | Unit | Source | Needs two polls |
|------|------|--------|-----------------|
| `clients_total`, `clients_<if>` | count | hostapd `get_clients` (authorized stations), fallback `iwinfo assoclist` | no |
| `rxkbps_<if>`, `txkbps_<if>` | kbit/s | `/sys/class/net/<if>/statistics` byte counter delta | yes |
| `airrx_<if>`, `airtx_<if>` | % of wall clock | summed per-client hostapd airtime (µs) delta | yes |
| `retries_<if>`, `failed_<if>` | 1/s | `iw station dump` sums, delta | yes |
| `busy_<phy>`, `rxpct_<phy>`, `txpct_<phy>` | % of channel active time | `iw survey dump` (in-use channel) delta | yes |
| `noise_<phy>` | dBm | `iw survey dump` (in-use channel) | no |
| `channel_<phy>` | channel number | `iw dev` (steps in the graph reveal DFS moves) | no |

All values are plain gauges: the rates are computed by the extension
itself from a state file (`$XYMONTMP/wifi.<host>.state`) between two
cron runs — no background process, no COUNTER/DERIVE handling on the
server. The first poll only primes the state file; rates appear with
the second poll.

## Data sources and fallbacks

1. **`iw dev`** (required) discovers the AP-mode interfaces, their
   radio (phy), SSID, channel/width and TX power.
2. **`ubus call hostapd.<if> get_clients`** (preferred, OpenWrt)
   delivers the client count — only stations with
   `"authorized": true` are counted — and the cumulative per-client
   airtime in microseconds.
3. **`iwinfo <if> assoclist`** is the client-count fallback when
   hostapd is not reachable over ubus. Note the small semantic
   difference: assoclist lists *associated* stations, hostapd counts
   *authorized* ones.
4. **`/sys/class/net/<if>/statistics/{rx,tx}_bytes`** provides the
   interface throughput. These counters are monotonic regardless of
   client comings and goings.
5. **`iw dev <if> station dump`** provides the summed TX retries and
   failures.

## Caveats

- The **airtime** sum only covers currently connected clients: when a
  client disconnects, the sum shrinks and the delta for that round is
  negative — the metric is skipped for one poll instead of reporting
  garbage. The same applies to retries/failed.
- Some drivers intermittently return an **empty station dump** even
  with clients associated (seen on a Turris Omnia); the retries/failed
  metrics are then omitted for that round. On devices where the dump
  is always empty those graphs stay empty.
- Some firmware reports **absolute survey counters with a huge
  garbage offset** (busy/rx/tx far beyond the channel active time;
  seen on a Zyxel NWA50AX Pro, mt798x). Since the utilization is
  computed from the deltas between two polls, it still works there.
  Only when the deltas themselves are implausible (busy/rx/tx growing
  faster than the active time) does the extension note it in the
  status and suppress the percentages; the noise floor is always
  reported.
- A counter reset (reboot, interface restart) skips the affected
  rates for one poll. A **32-bit counter wrap** (after ~49.7 days at
  ms resolution) looks the same - one negative delta - and is handled
  identically: the utilization is silently omitted for a single poll,
  then the re-primed state takes over. A wrap cannot fake a plausible
  delta (the counter would have to regain ~49 days within one poll).
- SSIDs are display-only; a `|` in an SSID is shown as `_`.

## Configuration

See the shipped `wifi.cfg` (installed to `$XYMONHOME/etc/wifi.cfg`);
every setting can also come from the environment, the config file
wins. Defaults work out of the box on OpenWrt/TurrisOS.

## Graphing (Xymon server setup)

See [`server/README.md`](server/README.md) — split-NCV setup plus the
graph definitions in [`server/graphs.d/wifi.cfg`](server/graphs.d/wifi.cfg).

## Packaging notes

- The `clientlaunch.d` snippet ships **disabled**: deb/rpm/FreeBSD targets
  are rarely access points. Enable it on a Linux AP with a full Xymon
  client, or — on OpenWrt/TurrisOS — run the extension through the
  standalone runner (it is part of the default `TESTS` list there).
- `iw` is deliberately **not** a hard package dependency: the same
  package installs on wired-only routers, where the column simply
  reports `clear` (or the extension is removed from `TESTS`).
