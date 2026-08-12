# opkg — Xymon **server** configuration

The extension puts two machine-readable lines into its status message
(hidden in an HTML comment — the NCV parser still sees them):

```
updates : 3
critical : 1
```

The Xymon server turns those into one `opkg.rrd` per host with two
datasets, via plain **NCV**. This is a one-time setup on the Xymon
server host.

Both steps are **drop-in files**: nothing in a stock Xymon config file
has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform (Debian/Ubuntu ship them ready to use).

## 1. xymonserver.d/opkg.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/opkg.cfg /etc/xymon/xymonserver.d/
```

```
TEST2RRD+=",opkg=ncv"
NCV_opkg="updates:GAUGE,critical:GAUGE"
GRAPHS+=",opkgupd"
GRAPHS_opkg="opkgupd"
```

## 2. graphs.d/opkg.cfg

Copy the graph definition shipped next to this README:

```sh
cp graphs.d/opkg.cfg /etc/xymon/graphs.d/
```

## 3. Restart / verify

Restart the Xymon server (a restart, not a reload — on Debian/Ubuntu
the list of included drop-in files is regenerated at start). After the
next report, check that the RRD file appears:

```
ls $XYMONVAR/rrd/<host>/opkg.rrd
```

## Alerting

The column goes yellow when updates are pending and red when one of
them matches the security-relevant patterns configured on the client,
so a normal `alerts.cfg` rule is enough, e.g.:

```
HOST=* TEST=opkg
    MAIL admin@example.com COLOR=red REPEAT=24h
```
