# powerline - server-side PLC monitoring

A POSIX sh collector for HomePlug AV adapters on the Xymon server's Ethernet
segment. Each adapter gets its own `HOST.powerline` status and per-pair
graphs; the collector itself reports on the server's host. It only reads:
no PLC counter reset, no device setting, no hosts.cfg edit.

Server-only: shipped exclusively in my-xymon-extensions-server (Debian/Ubuntu),
disabled on installation. Requires Linux, open-plc-utils (`plcstat`,
`plcrate`), iproute2, flock, sudo and the Xymon server environment. QCA7500
support is based on recorded real output, not an upstream guarantee.

## Install and enable

The package installs the programs in /usr/lib/xymon/server/ext, the config in
/etc/xymon/my-xymon-extensions-server and drop-ins in xymonserver.d, graphs.d
and tasks.d. It installs no open-plc-utils, grants no sudo, edits no stock
config and restarts nothing.

1. Install `plcstat` and `plcrate` as root-owned /usr/bin/plcstat and
   /usr/bin/plcrate - the privileged helper uses exactly these paths.
2. Grant the sudo rule: /etc/sudoers.d/my-xymon-extensions-server ships with
   its single rule commented out. Remove the `#`, then run `visudo -c`. The
   file is a conffile, so the edit survives upgrades. Other platforms: copy
   powerline.sudoers from the docs, root:root 0440, no dot in the file name
   (sudo ignores such files). The helper and all its parent directories must
   not be writable by xymon - otherwise the rule is a root shell; postinst
   warns if they are. Never grant sudo for powerline.sh or the plc tools.
3. Edit /etc/xymon/my-xymon-extensions-server/powerline.cfg: interface,
   optionally POWERLINE_COLLECTOR_HOST. State lives in $XYMONVAR/powerline
   (local disk, writable by xymon).
4. Make sure xymonserver.d, graphs.d and tasks.d are read after the stock
   settings. Debian's init script regenerates its include lists at start;
   elsewhere add `optional directory ...` lines. postinst reports what is
   missing.
5. Preview as xymon, read-only (sends nothing, keeps the state):
   `xymoncmd --env=/etc/xymon/xymonserver.cfg /usr/lib/xymon/server/ext/powerline.sh --config /etc/xymon/my-xymon-extensions-server/powerline.cfg --set POWERLINE_ENABLED=1 --set POWERLINE_SILENT=0 --verbose --dry-run`
6. Set POWERLINE_ENABLED=1. The task runs every 5 minutes (MAXTIME 4m,
   status lifetime 15 minutes); flock prevents overlapping runs. Errors go to
   $XYMONSERVERLOGS/powerline.log and syslog (tag `powerline`).

Precedence: CLI > exported environment > config file > defaults. The config
is passed with `--config` and never included into xymonserver.cfg, so it
takes effect at the next run without a restart. `--help` lists all settings.

## Identity

An adapter is matched to a Xymon host by, in this order: static mapping
(powerline.map: `PLC-MAC hostname`), its BDA in the mapping, then passive
IPv4 neighbor entries against hosts.cfg (CLIENT aliases included, includes
expanded by `xymoncfg`). No DNS, no ARP probing. A local adapter is matched
by its PLC MAC only, its BDA may be the server's own NIC. A known identity
survives neighbor-cache expiry.

Ambiguous or unknown adapters report as `powerline-unknown-MAC`, which xymond
lists as a ghost unless you add the host. A CLIENT alias that is also a host
name, or claimed by two hosts, is ignored (logged); a static mapping to such
a name is red. Several adapters mapped to one host: worst color wins.

## Topology changes

The first successful poll is the baseline. An adapter appearing, disappearing
or changing its peers turns yellow for 60 minutes (POWERLINE_CHANGE_MINUTES);
every further change restarts that hold. A change episode lasting 180 minutes
(POWERLINE_FLAP_MINUTES) turns red with the summary **state flapping**. One
quiet hour clears it. An absent adapter is then green (graphs unknown) until
POWERLINE_RETENTION_DAYS (default 1) after it was last seen; then it is
forgotten, and its column goes purple once the last status expires (15
minutes later) - drop it in Xymon or remove the host. 0 keeps absent
adapters forever.

Failures are not absence: a timeout, empty or unparsable output, a permission
error or a broken hosts/neighbor lookup turns the collector and all known
adapters red and keeps the state. A failed pair only turns its adapter red. A
failed delivery keeps the old state for the next run. A clock running
backwards is reported as an error.

## Metrics

Legend (also appended to every status message):

- **PB** - PHY block, the 520-byte unit HomePlug AV sends over the powerline.
  A PB that fails its check is resent.
- **MPDU** - MAC protocol data unit, one powerline frame carrying PBs;
  counted as acknowledged, failed and (TX) collisions.
- **BER** - bit errors seen by the FEC (turbo) decoder, summed over the
  received PBs that passed and failed. *fec* is these errors as a share of
  all received bits (upstream's FEC-BER, 4160 bits per PB).
- **aMAC_pMAC** - reporting adapter and peer; TX/RX are seen from the
  reporting adapter. **slotN** - receive slot. **_interval_pct** - since the
  last poll, **_reported_pct** - since device reset.

`plcrate` supplies TX/RX PHY rates (negotiated, not throughput); `plcstat` the
counters. Interval values are counter deltas over the actual elapsed time;
PB error is `100 * fail / (pass + fail)`. First samples, resets, gaps longer
than POWERLINE_MAX_SAMPLE_GAP, idle links and counters above 2^53 give
unknown, never zero.

Thresholds (all off by default): PHY WARN/CRIT are minima, PB WARN/CRIT are
maxima of the interval PB error, separately for TX and RX.

## Graphs

Every metric is its own GAUGE RRD, `powerline,aMAC_pMAC_metric.rrd`, written
from native trends messages so missing samples stay `U`. The status page
shows 17 graphs (GRAPHS_powerline): PHY, interval error ratios, rates,
lifetime ratios, cumulative counters, presence. One graph holds one metric
family at one scale, and every RRD is drawn by exactly one graph -
tests/powerline/run.sh pins both. Only the `powerline` graph appears on the
trends page. RRD history is kept when an adapter leaves.

## References and test scope

- [tasks.cfg](https://xymon.sourceforge.io/xymon/help/manpages/man5/tasks.cfg.5.html),
  [xymond ghosts](https://xymon.sourceforge.io/xymon/help/manpages/man8/xymond.8.html),
  [xymoncfg](https://xymon.sourceforge.io/xymon/help/manpages/man1/xymoncfg.1.html)
- [Native trends parser](https://github.com/xymon-monitoring/xymon/blob/master/xymond/rrd/do_trends.c)
- [PLC statistics and formulas](https://github.com/qca/open-plc-utils/blob/master/plc/LinkStatistics.c)

The tests replay recorded output through fake helpers; no PLC hardware, sudo
policy or real Xymon wiring is exercised. `make graphcheck` renders the graphs
with real RRDtool (Python 3 + rrdtool).
