# if_link — Xymon **server** configuration

The extension sends a `data` message with one `NAME : VALUE` line per
interface (`changes_lan4 : 2`, …). The Xymon server turns those into
RRD files and graphs via **split-NCV**. This is a one-time setup on
the Xymon server host.

## 1. xymonserver.cfg

The metric is a plain gauge (the extension computes the delta itself,
so no COUNTER/DERIVE handling is needed). Append:

```
TEST2RRD+=",if_link=ncv"
SPLITNCV_if_link="*:GAUGE"
```

Note the leading comma: `+=` concatenates verbatim and does not
insert a separator.

To make the graph appear on the trends column and on the `if_link`
status page, also extend:

```
GRAPHS+=",iflink"
GRAPHS_if_link="iflink"
```

## 2. graphs.cfg

Include the graph definition shipped in this directory
(`graphs.d/if_link.cfg`):

```
include /etc/xymon/graphs.d/if_link.cfg
```

or append the contents of `graphs.d/if_link.cfg` to your `graphs.cfg`.

## 3. Restart / verify

Restart the Xymon server (or `xymon @ "rotate"` plus a xymond_rrd
restart). After the second poll (the first one only primes the delta
calculation), check that RRD files appear:

```
ls $XYMONVAR/rrd/<host>/if_link,*
```

One file per monitored interface — the number varies with the host's
ports, which is expected; the FNPATTERN in `graphs.d/if_link.cfg`
picks up whatever exists.

## Alerting

With no thresholds configured the column never leaves `green`, so no
`alerts.cfg` entry is needed — watch the graph instead. If you do set
`IF_LINK_YELLOW`/`IF_LINK_RED` (or `IF_LINK_THRESHOLDS`) on a client,
the column turns yellow/red like any other and the usual `alerts.cfg`
rules apply, e.g.:

```
HOST=router.example.com COLUMN=if_link
    MAIL admin@example.com REPEAT=6h
```

A flapping port typically recovers on its own before the next poll, so
a `DURATION>10m` clause is a good way to keep single events out of
your inbox while still catching a port that keeps bouncing.
