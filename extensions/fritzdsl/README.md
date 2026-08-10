# fritzdsl — AVM FRITZ!Box DSL line monitoring

Polls an AVM FRITZ!Box over its **TR-064** SOAP interface (HTTP digest
authentication, `curl`) and reports the DSL line state as the Xymon
column **`fritzdsl`**, attached to the box's own host entry.

Unlike the other extensions in this repository, this is a **poller**:
it runs on the Xymon server itself (or any host that can reach the
box) — nothing is installed on the FRITZ!Box.

## What it reports

Status color:

| Condition | Color |
|-----------|-------|
| DSL line status not `Up` | red |
| Box unreachable / TR-064 request failed | red |
| Noise margin below `MARGIN_CRIT` (default 3 dB) | red |
| Noise margin below `MARGIN_WARN` (default 6 dB) | yellow |
| CRC error rate above `CRC_RATE_CRIT`/`CRC_RATE_WARN` per minute | red / yellow |
| WAN connection (PPP/IP) not `Connected` | yellow |
| TR-064 authentication failed | yellow |
| `curl` missing, or the box has no DSL service | clear |

Metrics (sent as a `data` message for RRD graphing, see
[server/README.md](server/README.md)):

| Variable | Source (TR-064) | Unit | RRD type |
|----------|-----------------|------|----------|
| `rate_down`, `rate_up` | `WANDSLInterfaceConfig:1` `GetInfo` | kbit/s | GAUGE |
| `maxrate_down`, `maxrate_up` | `GetInfo` (attainable rate) | kbit/s | GAUGE |
| `margin_down`, `margin_up` | `GetInfo` (noise margin) | dB | GAUGE |
| `atten_down`, `atten_up` | `GetInfo` (attenuation) | dB | GAUGE |
| `crc`, `fec`, `hec` | `GetStatisticsTotal` (cumulative) | errors | DERIVE |
| `es`, `ses` | `GetStatisticsTotal` ((severely) errored seconds) | s | DERIVE |
| `retrain` | `GetStatisticsTotal` (link retrains) | count | DERIVE |
| `uptime` | `WANPPPConnection:1`/`WANIPConnection:1` `GetStatusInfo` | s | GAUGE |

The dB values arrive from the box in tenths of a dB and are converted
(`65` → `6.5`). The error counters are cumulative since the last
resync; stored as DERIVE they graph as error *rates*. Additionally the
extension keeps the previous poll's CRC counter in a state file under
`$XYMONTMP` and colors the column when the per-minute CRC rate exceeds
the configured thresholds. A backwards jump of the WAN uptime is shown
as a "connection was re-established" note.

## Setup

1. **On the FRITZ!Box**: enable TR-064 (Home Network > Network >
   Network Settings > *Allow access for applications*) and create a
   dedicated user (System > FRITZ!Box Users) with the *FRITZ!Box
   settings* permission.
2. **Configure** `$XYMONHOME/etc/fritzdsl.cfg` on the polling host
   (normally the Xymon server): set `FRITZ_USER`, `FRITZ_PASSWORD`
   (or `FRITZ_PASSWORD_FILE`), and `FRITZ_HOST`/`REPORTHOST` if the
   box is not reachable as `fritz.box`. `chmod 600` the file.
3. **Add the box to `hosts.cfg`** on the Xymon server, e.g.:

   ```
   192.168.178.1  fritz.box  # conn
   ```

   `REPORTHOST` must match this hostname. The `fritzdsl` column
   appears on this host; `conn` gives you a basic ping check for free.
4. **Enable the task**: the shipped
   `clientlaunch.d/fritzdsl.cfg` snippet is `DISABLED` by default — remove
   that line after configuring the credentials, then restart the
   Xymon client on the polling host.
5. **Server-side RRD/graph setup**: see [server/README.md](server/README.md).

A quick manual test (prints the report to stdout when `$XYMON` is not
set):

```sh
XYMONHOME=/usr/lib/xymon/client ./fritzdsl.sh
```

## Verifying the connection by hand

```sh
curl -s --digest -u "USER:PASSWORD" \
  -H 'Content-Type: text/xml; charset="utf-8"' \
  -H 'SOAPACTION: "urn:dslforum-org:service:WANDSLInterfaceConfig:1#GetInfo"' \
  -d '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetInfo xmlns:u="urn:dslforum-org:service:WANDSLInterfaceConfig:1"/></s:Body></s:Envelope>' \
  "http://fritz.box:49000/upnp/control/wandslifconfig1"
```

An XML response containing `<NewDownstreamNoiseMargin>` confirms that
TR-064 and the credentials work. The exact set of fields varies
between FRITZ!OS versions; the extension skips fields the box does
not report.

## Platform notes

- Requires `curl` (reports `clear` without it). Runs on every target
  platform of this repository, including the `standalone/` runner —
  but the natural place is the Xymon server.
- Only one FRITZ!Box per config file. To monitor several boxes, run
  the script once per box with `FRITZDSL_CFG=<file>` pointing to a
  separate config (each with its own `REPORTHOST`).
- Boxes without DSL (cable/fiber/LTE FRITZ!Box) report `clear`.
