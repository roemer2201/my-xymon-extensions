# wifi — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
metric (`clients_phy0_ap0 : 5`, `busy_phy0 : 20.0`, …). The Xymon
server turns those into RRD files and graphs via **split-NCV**. This
is a one-time setup on the Xymon server host.

Both steps are **drop-in files**: nothing in a stock Xymon config file
has to be edited. See
[Server-side setup: drop-in directories](../../../README.md#server-side-setup-drop-in-directories)
in the top-level README for how those directories are wired up on your
platform (Debian/Ubuntu ship them ready to use).

## 1. xymonserver.d/wifi.cfg

Copy the snippet shipped next to this README into the server's
drop-in directory:

```sh
cp xymonserver.d/wifi.cfg /etc/xymon/xymonserver.d/
```

All wifi metrics are plain gauges (the extension computes the rates
itself, so no COUNTER/DERIVE handling is needed):

```
TEST2RRD+=",wifi=ncv"
SPLITNCV_wifi="*:GAUGE"
GRAPHS+=",wificlients,wifiutil,…"
GRAPHS_wifi="wificlients,wifiutil,wifikbps,wifiair,wifierr,wifinoise,wifichan"
```

## 2. graphs.d/wifi.cfg

Copy the graph definitions shipped next to this README:

```sh
cp graphs.d/wifi.cfg /etc/xymon/graphs.d/
```

## 3. Restart / verify

Restart the Xymon server (a restart, not a reload — on Debian/Ubuntu
the list of included drop-in files is regenerated at start). After the
second poll (the first one only primes the rate calculation), check
that RRD files appear:

```
ls $XYMONVAR/rrd/<ap-host>/wifi,*
```

The number of RRD files varies with the host's radios and SSIDs —
that is expected; the FNPATTERNs in `graphs.d/wifi.cfg` pick up
whatever exists.

## Alerting

The column is purely informational and never turns yellow/red, so no
`alerts.cfg` entry is needed. Watch the graphs instead (channel busy
percent and airtime are the interesting ones for capacity planning).

## FRITZ! devices

The server-side [fritz-wifi](../../fritz-wifi/server/README.md) collector
reports FRITZ! devices (e.g. FRITZ!Powerline) into this same column and
RRD files over TR-064. It needs nothing beyond the drop-ins above.

## Upgrading: stray files and mangled names

Two old bugs left RRD files behind that no graph shows. The RRD schema
(`wifi,<name>.rrd`, one GAUGE data source `lambda`) never changed, so
existing graphs keep their history.

**Stray files from the status text** (fixed in 0.24.0). xymond_rrd feeds
the status text of an NCV column to the NCV parser as well, and that
parser takes `name=number` like `name : number`. So `phy1  channel=36`
created `wifi,phy1_channel.rrd` and `rx=0.0 tx=...` created `wifi,rx.rrd`.
The details are now wrapped in `<!-- ncv_skipstart -->` /
`<!-- ncv_skipend -->` (invisible on the page; supported by Xymon 4.3.30).
Once every access point runs 0.24.0 or later, the leftovers can go:

```
cd /var/lib/xymon/rrd/<ap-host>
ls wifi,phy*_channel.rrd wifi,rx.rrd
rm -f wifi,phy*_channel.rrd wifi,rx.rrd
```

**`why0_aw0` instead of `phy0_ap0`** (access points on 0.18.0 or older).
BusyBox `tr` does not know `[:upper:]`/`[:lower:]` and translated the
letters instead (p -> w, u -> l), so the interface part of the file
names came out as `wifi,clients_why0_aw0.rrd`, `wifi,busy_why1.rrd` and
so on. Newer versions write `phy0_ap0`, i.e. new files, and the graphs
start over. To keep the history, rename the old files once - **before**
the access point is updated, because afterwards the new names already
exist:

```
cd /var/lib/xymon/rrd/<ap-host>
for f in wifi,*_why[0-9]*.rrd; do
    [ -e "$f" ] || continue
    new=$(printf '%s\n' "$f" | sed -e 's/_why\([0-9][0-9]*\)/_phy\1/' -e 's/_aw\([0-9][0-9]*\)/_ap\1/')
    if [ -e "$new" ]; then echo "exists, skipped: $new"; else mv -- "$f" "$new"; fi
done
```

Then update the access point. Until it runs the new version, the old one
recreates `why`/`aw` files (a few minutes' worth); delete those
afterwards. The pattern only matches `_why<digits>` and `_aw<digits>`,
i.e. the mangled OpenWrt names `phyN` and `phyN-apM`.
