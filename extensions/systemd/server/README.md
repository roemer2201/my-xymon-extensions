# systemd — Xymon **server** configuration

From its second poll on, the extension sends a `data` message with two
lines:

```
failed : 3
restarts : 1
```

`failed` is the number of failed units right now, `restarts` the
number of automatic service restarts since the previous poll. The
Xymon server turns them into one `systemd.rrd` per host with two
datasets, via plain **NCV** (a fixed set of metrics — no split-NCV
needed). This is a one-time setup on the Xymon server host.

On Debian/Ubuntu the `my-xymon-extensions-server` package installs all
three files below; otherwise copy them by hand. All of them are
**drop-in files**: nothing in a stock Xymon config file has to be
edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform.

## 1. xymonserver.d/systemd.cfg

```sh
cp xymonserver.d/systemd.cfg /etc/xymon/xymonserver.d/
```

```
TEST2RRD+=",systemd=ncv"
NCV_systemd="failed:GAUGE,restarts:GAUGE"
GRAPHS+=",systemd"
GRAPHS_systemd="systemd"
```

Both are gauges: the extension computes the restarts per poll itself.

## 2. rrddefinitions.d/systemd.cfg

```sh
cp rrddefinitions.d/systemd.cfg /etc/xymon/rrddefinitions.d/
```

On Debian/Ubuntu that directory does not exist yet — create it and add
one line at the end of `/etc/xymon/rrddefinitions.cfg` (the server
package's post-install output says so when it is missing):

```
optional directory /etc/xymon/rrddefinitions.d
```

It keeps Xymon's default AVERAGE archives and adds a matching set of
**MAX** archives. A service restart is a single event, like a link
change of the `if_link` extension, and the same two RRDtool effects
apply: the value is split across two 5-minute slots, and AVERAGE
consolidation dilutes it until it is invisible in a graph longer than
48 hours. The `if_link` server README explains both in detail
([Why the graph showed 0.4](../../if_link/server/README.md#why-the-graph-showed-04)).

The section is keyed `[systemd]`, i.e. by the column name:
`xymond/do_rrd.c` looks the RRA definition up with the test name.

`rrddefinitions.cfg` is only consulted when an RRD file is
**created**. Install this file before the first `data` message of a
client arrives. If `systemd.rrd` files exist already, stop the server,
delete them once and start it again (`rrdtool tune` cannot add an
archive to an existing file):

```sh
service xymon stop                       # or: systemctl stop xymon
rm $XYMONVAR/rrd/*/systemd.rrd
service xymon start
```

## 3. graphs.d/systemd.cfg

```sh
cp graphs.d/systemd.cfg /etc/xymon/graphs.d/
```

One graph, `[systemd]`, with two lines drawn from the MAX archives:

- **Failed units** — with current and maximum value.
- **Restarts per poll** — with its peak and the exact number of
  restarts in the shown window as `(total)`, integrated from the
  AVERAGE archive. That figure is exact as long as the poll interval
  equals the RRD step of 300 s, i.e. keep the task at `INTERVAL 5m`.

Without MAX archives rrdtool silently falls back to AVERAGE, so the
graph renders either way.

## 4. Restart / verify

Restart the Xymon server (a restart, not a reload — on Debian/Ubuntu
the list of included drop-in files is regenerated at start). After the
second report of a client, check the RRD file and its MAX archives:

```sh
ls $XYMONVAR/rrd/<host>/systemd.rrd
rrdtool info $XYMONVAR/rrd/<host>/systemd.rrd | grep 'cf = "MAX"'
```

The `grep` must print four lines.

## Alerting

The column turns red for failed units and required units that are
down, and yellow for automatic restarts (for 30 minutes after the
last one), so ordinary `alerts.cfg` rules apply, e.g.:

```
HOST=* COLUMN=systemd
    MAIL admin@example.com COLOR=red REPEAT=4h
```

Add `COLOR=yellow,red` to be told about crashing services too. A host
that reboots shows `starting`/`stopping` (yellow by default) for a
poll or two; a `DURATION>10m` clause keeps those out of your inbox.
