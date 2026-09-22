# Powerline server setup

## Install and enable

The Debian/Ubuntu server package installs programs under
/usr/lib/xymon/server/ext, configuration under
/etc/xymon/my-xymon-extensions-server, and drop-ins in xymonserver.d,
graphs.d and tasks.d. No clientlaunch.d entry is installed. Those two
directories are packaging arguments (stage-server.sh BINDIR/ETCDIR) and the
installed task, sudoers example and include line follow them, so the paths
below are the ones this package uses, not ones the collector assumes.
It does not install open-plc-utils, grant sudo, modify stock configs, or restart
Xymon. POWERLINE_ENABLED=0 prevents collection until setup is complete.

1. Install plcstat and plcrate as root-owned /usr/bin/plcstat and
   /usr/bin/plcrate. The privileged helper intentionally fixes these paths,
   clears tool environment, validates every argument and permits only topology,
   PHY and peer-statistics reads. Requests have a fixed 15-second timeout.
2. Inspect the shipped powerline.sudoers example. Install it root:root 0440
   under /etc/sudoers.d using visudo; validate with visudo -c. The helper and
   all its parent directories must not be writable by xymon. Do not grant
   sudo for powerline.sh, a shell, or unrestricted open-plc-utils commands.
3. Edit /etc/xymon/my-xymon-extensions-server/powerline.cfg. Set eth0 or the
   appropriate interface, optionally a canonical POWERLINE_COLLECTOR_HOST.
   Persistent state defaults to $XYMONVAR/powerline; its parent must be
   writable by xymon. Override POWERLINE_STATE_DIR if necessary. Keep it on
   local storage; all invocations must use the same state directory.
4. The xymonserver.d drop-in contains the requested native include:
   `include /etc/xymon/my-xymon-extensions-server/powerline.cfg`.
   Ensure the drop-in directory is read after stock settings. On the target
   Debian/Ubuntu layout, the init script regenerates include lists at startup.
   Likewise verify graphs.d and tasks.d are included. Do not add a second
   directory directive if an existing generated include already covers it.
   Other layouts can use `optional directory /etc/xymon/tasks.d` in tasks.cfg
   and the corresponding xymonserver.d/graphs.d directives in their configs.
5. Run a read-only preview as xymon in the server environment:
   `xymoncmd --env=/etc/xymon/xymonserver.cfg /usr/lib/xymon/server/ext/powerline.sh --set POWERLINE_ENABLED=1 --set POWERLINE_SILENT=0 --verbose --dry-run`.
   This reads PLC devices but sends nothing and does not change the snapshot.
   It does create transient lock/work files under the state directory.
6. Set POWERLINE_ENABLED=1, then restart Xymon at a time you choose. The task
   uses INTERVAL 5m, MAXTIME 4m, and status+15. The timeout prevents overlapping
   long collections; flock also protects manual invocations. stderr goes to
   $XYMONSERVERLOGS/powerline.log; events are logged with syslog tag powerline.

Config precedence is defaults < config < exported environment < CLI. Settings
loaded by xymonlaunch are environment settings: restart after changing them,
or use CLI overrides during previews. --help lists all parameters.

## Identity and topology

Matching is explicit PLC-MAC mapping first, then REM BDA mapping, then passive
IPv4 neighbor entries matched against canonical hosts.cfg names. A LOC BDA
may be the server's NIC, so local adapters use their PLC MAC only. Multiple
IPs resolving to the same canonical host are fine; conflicting hostnames
are not guessed. CLIENT aliases are canonicalized. Includes are expanded by
$XYMONHOME/bin/xymoncfg (override POWERLINE_XYMONCFG); without that program
only a flat hosts.cfg is accepted. No DNS lookup or active ARP probing is used.
Known identity survives neighbor-cache expiry. A static map is two fields:
PLC-MAC canonical-hostname. Examples for the supplied devices are commented
in powerline.map. This also handles adapters with downstream switched clients:
one PLC link cannot measure the individual IP clients' throughput.

A hosts.cfg name that is also another host's CLIENT alias is not an error:
the real host name wins and the alias is dropped, whatever the file order.
An alias two hosts claim resolves to neither. Both cases are reported in
$XYMONSERVERLOGS/powerline.log and cost only that one name - the collector
keeps running. A static mapping pointing at such a name is red, however.
An absent POWERLINE_MAPPING file simply means no static mapping.

Unknown/conflicting identities use powerline-unknown-MAC, avoiding real-name
collisions. Status is still sent. With xymond's default --ghosts=log, it is
dropped and recorded in the native ghost list (ghostlist.cgi); --ghosts=allow
accepts it instead and does NOT provide the same ghost-list semantics.
There is no private ghost log or automatic hosts.cfg insertion. Source IP in
the ghost list is the collector, not the remote adapter. For ghost hosts,
usable graphs require admission by the server / a corresponding hosts entry.

The first successful inventory is the baseline. Later additions, removals,
reappearances, and local peer-membership changes immediately start yellow.
Every transition restarts a 60-minute hold. The beginning of the continuous
warning episode is preserved: after 180 minutes, status is red with the exact
summary **state flapping**. A full quiet hour clears either warning or red.
At the exact quiet deadline a new observed event continues the same episode.
Thus a removal detected at minute 5 stays yellow until minute 65. Afterwards
the absent adapter's current status is green with no disappearance narrative;
its measurement graphs remain unknown. Reappearance starts a new yellow hold.

Each adapter is evaluated separately. If static mappings deliberately group
several adapters under one Xymon host, the worst color wins but metric keys
stay separate. Xymon's built-in color-flap detection is independent of this
topology timer; existing noflap/delay settings can affect display/alerts.

Timeout, empty output, changed output format, permission failure or a broken
neighbor/hosts lookup is not evidence of disappearance. Global collector
failure marks the collector and previously known hosts red and keeps state.
A failure of one pair's statistics marks that adapter red, with missing values
unknown. Delivery failure retains the old snapshot for retry. Partial message
delivery cannot be transactional across Xymon hosts; a retry may repeat status.
A backward system clock causes a visible failure rather than rewriting timers.

## Metrics, limits and graphs

plcrate supplies TX/RX PHY. plcstat supplies cumulative PB pass/fail, MPDU
ACK/fail, TX collision count, printed ratios, and RX slot PHY/PB/BER sums.
The extra unlabelled TX field is the collision count. Slots are receive-side
only, queried independently at each endpoint. ALL is not added to slot sums.
BER ERR is the failed-BER-sum fraction, not FEC BER; the final ALL percentage
is FEC BER. The code preserves both with different names.

Intervals use counter differences divided by actual elapsed time. PB error
is 100 * delta(fail) / (delta(pass) + delta(fail)); the FEC formula follows
upstream's 4160 bits per PB. Initial samples, resets, long gaps, and no-traffic
ratios are unknown. Portable awk cannot safely difference integers above
2^53-1: those raw counters are retained but derived rates remain unknown.
Counter wrap is treated as reset. Undetectable device resets that already
overtake the previous count between polls cannot be distinguished.

PHY WARN/CRIT are minima; PB WARN/CRIT are maxima, separately for TX and RX.
Comparison is strict (< for PHY, > for PB). off disables an individual bound.
All ship off. A critical enabled quality limit overrides topology yellow.
Quality is evaluated from interval PB percentages, not the lifetime totals.

Each metric is a separate GAUGE RRD with DS value, heartbeat 600 seconds:
`powerline,aREPORTINGMAC_pPEERMAC_metric.rrd`. The MAC legend identifies the
pair; the status body supplies host mapping. slotN names preserve slot identity.
Native `data HOST.trends` messages send U directly for missing samples:
unlike NCV, no numeric sentinel, fake zero, or graph masking is required.
Default Xymon RRA retention applies; no extra RRD template is needed.

The [powerline] overview is registered in GRAPHS so the trends page can
discover it from filenames; the trends page matches graph names against the
start of the RRD file name, so only that one can appear there. GRAPHS_powerline
adds PB, MPDU, slot PHY, slot PB, BER, FEC, reported/interval ratios,
cumulative counters and presence graphs to the status page. TEST2RRD carries
the column as well: it is what makes svcstatus.cgi look at GRAPHS_powerline at
all, and it does not route the status message to any xymond_rrd parser. Retained RRD history is not deleted when a device
leaves. Check both the status graph list and trends after two successful polls.

## References and validation boundary

- [Task syntax](https://xymon.sourceforge.io/xymon/help/manpages/man5/tasks.cfg.5.html)
- [Ghost modes](https://xymon.sourceforge.io/xymon/help/manpages/man8/xymond.8.html)
- [Hosts include expansion](https://xymon.sourceforge.io/xymon/help/manpages/man1/xymoncfg.1.html)
- [Native trends parser](https://github.com/xymon-monitoring/xymon/blob/master/xymond/rrd/do_trends.c)
- [PLC statistics layout/formulas](https://github.com/qca/open-plc-utils/blob/master/plc/LinkStatistics.c)

Automated tests use recorded/synthetic stdout and fake read-only helpers;
they do not access PLC hardware. Hardware operation, sudo policy, actual
server include wiring and graph rendering require the administrator's preview
and installation checks. The preverified tool behavior was not retested.
Run make test for collector/replay/packaging tests and make graphcheck for
real RRDtool graph rendering and unknown-value storage (Python 3 + RRDtool).
