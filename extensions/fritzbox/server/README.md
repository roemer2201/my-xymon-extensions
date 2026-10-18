# fritzbox - AVM FRITZ!Box monitoring via TR-064

A POSIX sh collector that runs on the Xymon **server**, polls AVM
FRITZ!Box routers over TR-064 (and UPnP/IGD for the WAN counters) and
reports up to seven columns on each box's host:

| Module | Column | Content |
|--------|--------|---------|
| `dsl` | `fritzdsl` | DSL line state, sync/attainable rate, noise margin, attenuation, error counters (near and far end), CRC rate, WAN uptime |
| `wan` | `fritzwan` | WAN link state, throughput, packet rate, link capacity, utilization |
| `sys` | `fritzsys` | model, FRITZ!OS version, firmware updates, uptime/reboot, clock offset |
| `log` | `fritzlog` | new entries of the box's event log, classified by a rules file |
| `fw` | `fritzfw` | port mappings, UPnP port sharing, remote access, MyFRITZ, DynDNS |
| `lan` | `fritzlan` | LAN throughput, host counts, required devices, new devices |
| `tel` | `fritztel` | SIP account registration, DECT handsets |
| `plc` | - | the box's powerline adapter list, shown by [powerline](../../powerline/server/README.md) |

Reference device: FRITZ!Box 7510 (1&1), FRITZ!OS 8.26, VDSL 35b over
PPPoE, TR-064 on HTTP port 49000. Other models are not excluded, but
untested. One poll per box and run: one device description, one login
check, then the enabled modules.

It only reads: every request is a `Get` action, and the actions that
return secrets (`GetSecurityKeys`, `X_AVM-DE_GetVoIPAccount`,
`X_AVM-DE_GetClient*`, `X_AVM-DE_GetConfigFile`) are refused by the
collector itself. User names, domains and e-mail addresses that some
answers contain are never put into a status. No device setting, no
hosts.cfg edit.

Server-only: shipped exclusively in my-xymon-extensions-server
(Debian/Ubuntu), disabled on installation. Requires curl, flock and the
Xymon server environment. Up to 0.28 fritzdsl and fritzwan were client
extensions; see [Migration](#migration-from-the-fritzdsl-and-fritzwan-client-extensions).

## Setup

1. **On the FRITZ!Box**: allow TR-064 (Home Network > Network > Network
   Settings > *Allow access for applications*), and for the 64-bit WAN
   counters *Transmit status information over UPnP* on the same page.
   Create a user (System > FRITZ!Box Users) with the permission
   *FRITZ!Box Settings*. Since FRITZ!OS 7.24 TR-064 always needs a user
   name, even if the web interface only asks for a password; the box's
   users are listed (from the home network, without login) by
   `curl -s "http://fritz.box/login_sid.lua?version=2"`.
2. **Password file** - the one fritz-wifi uses, one line per device:

   ```sh
   install -o xymon -g xymon -m 600 /usr/share/doc/my-xymon-extensions-server/fritz-wifi/fritz.passwd.example \
       /etc/xymon/my-xymon-extensions-server/fritz.passwd
   # then add a line:  fritz.box   xymon   the password
   ```

   `root:xymon` with mode 640 is accepted as well; anything else is
   rejected. The password reaches curl only on stdin.
3. **hosts.cfg**: tag the box, e.g.
   `192.168.178.1  fritz.box  # fritzbox`. The collector connects to the
   IP address and reports on the host name.
4. **Try it** while the collector is still disabled - `--set` switches it
   on for this one run only:

   ```sh
   sudo -u xymon xymoncmd --env=/etc/xymon/xymonserver.cfg \
       /usr/lib/xymon/server/ext/fritzbox.sh \
       --config /etc/xymon/my-xymon-extensions-server/fritzbox.cfg \
       --set FRITZBOX_ENABLED=1 --dry-run --verbose
   ```

   prints every status and trends message without sending them. Without
   `--set FRITZBOX_ENABLED=1` the shipped config ends the run with
   "disabled"; without the hosts.cfg tag it ends with "No host tagged
   fritzbox" (`--host fritz.box` polls one box regardless of the tag).
   A dry run saves no state, so the first real run is a baseline again.
5. **Enable**: `FRITZBOX_ENABLED=1` in
   `/etc/xymon/my-xymon-extensions-server/fritzbox.cfg`. The task
   (`/etc/xymon/tasks.d/fritzbox.cfg`) runs every 5 minutes. The graphs
   need a Xymon server restart once (the drop-ins in `xymonserver.d` and
   `graphs.d` are read at start).

## Colors

Common to all columns: the box unreachable is **red**; a refused login,
no password, no device description or an exhausted run budget is
**yellow**; curl missing is **clear**. A service the box does not offer
makes its column clear (e.g. fritzdsl on a cable box). Every setting
named `..._COLOR` accepts green, yellow or red; green turns the finding
into a note without changing the column color.

| Column | Yellow | Red |
|--------|--------|-----|
| fritzdsl | noise margin below 6 dB, CRC rate from 30/min, WAN connection not Connected | line not Up, margin below 3 dB, CRC rate from 300/min |
| fritzwan | utilization above FRITZBOX_WAN_UTIL_WARN (off) | link not Up, utilization above FRITZBOX_WAN_UTIL_CRIT (off) |
| fritzsys | update available, reboot within FRITZBOX_HOLD_MINUTES, clock offset above 60 s, factory default password still in use (FRITZBOX_SYS_DEFAULTPW_COLOR); last update failed only with FRITZBOX_SYS_UPDATE_FAILED_COLOR=yellow | clock offset above 300 s |
| fritzlog | a new entry of a yellow rule, or one no rule matches - for FRITZBOX_HOLD_MINUTES | a new entry of a red rule - for FRITZBOX_HOLD_MINUTES |
| fritzfw | a mapping outside FRITZBOX_FW_EXPECTED or an expected one missing; without that list, any change of mappings or settings for FRITZBOX_HOLD_MINUTES | (FRITZBOX_FW_COLOR=red) |
| fritzlan | a FRITZBOX_LAN_REQUIRED device not active; with FRITZBOX_LAN_NEW_MAC=1 a new MAC for FRITZBOX_HOLD_MINUTES | LAN interface not Up |
| fritztel | - | an enabled SIP account neither registered nor connected (FRITZBOX_TEL_COLOR) |

The first poll of fritzlog, fritzfw and the new-MAC check is a
**baseline**: nothing is reported as new or changed.

## The columns in detail

**fritzdsl** - `WANDSLInterfaceConfig` GetInfo, GetStatisticsTotal and
`X_AVM-DE_GetDSLInfo` (profile, modulation), the uptime of the
connected WAN service (`WANPPPConnection`, else `WANIPConnection`;
FRITZBOX_DSL_WAN_SERVICE). Margins and attenuation arrive in tenths of
a dB. The CRC rate is computed against the previous poll; a backwards
uptime is noted as "re-established" (on boxes that pre-empt the
provider's forced disconnect this happens once a day) and counted in
the DERIVE RRD `reconnect`; the count lives in the dsl state file. The
transmit
power (GetInfo `UpstreamPower`/`DownstreamPower`) is not used: its unit
is not documented.

**fritzwan** - link status and capacity from `GetCommonLinkProperties`,
traffic from the counters as the average rate since the last poll. The
link (`link_up`, 1 = Up) and the internet connection (`connected`, 1 =
Connected; the same `GetStatusInfo` answer fritzdsl uses, asked once
per poll) are recorded as 1/0 for the outage graph; they change no
color here - a connection that is not up is yellow in fritzdsl. With
FRITZBOX_WAN_MODE=auto the UPnP/IGD values come first: the IGD link
capacity is what the box's own online monitor uses as 100% (on the
reference box 233.1/45.5 Mbit/s, while TR-064 reports the attainable DSL
rate, 268.3/47.4), and `GetAddonInfos` has AVM's 64-bit counters. The
TR-064 fallback detects the counter width: FRITZ!OS 8 returns 64-bit
values there too, older versions 32-bit ones. A 32-bit wrap is corrected
only when the previous value was in the upper half of the range;
anything else going backwards is a reset (reboot), and that round has
no rate. The packet rate (`pps_down`/`pps_up`, packets per second) comes
from `GetTotalPacketsReceived`/`GetTotalPacketsSent` in the same order,
IGD before TR-064, with the same width detection (the reference box
returns 32-bit values on both). IGD and TR-064 are separate counters -
on the reference box they differ by millions of packets at the same
moment - so the state files `HOST.wan` and `HOST.wanpkt` record the
source, and a poll that has to switch it has no rate. A `HOST.wan` of
0.30.0 or earlier names no source: the first poll after the update
shows no throughput. The `NewPacketSendRate`/`NewPacketReceiveRate`
fields of `GetAddonInfos` are not used: the reference box reports 0
there.

**fritzsys** - DeviceInfo GetInfo (model, `SoftwareVersion` 271.08.26 =
hardware 271, FRITZ!OS 8.26, uptime), UserInterface GetInfo and
`X_AVM-DE_GetInfo` (update available, update state, automatic updates,
previous version, result of the last update), LANConfigSecurity GetInfo
(`X_AVM-DE_IsDefaultPasswordActive`: the factory default password from
the label is still in use; a box without the field shows "unknown" and
no color) and Time GetInfo (box time and NTP servers). The clock offset is the box time minus the server
time at the reply. "Last update failed" is a note by default: the box
may keep that value until the next successful update.

**fritzlog** - DeviceInfo GetDeviceLog. Entries are found by their time
stamp (`dd.mm.yy hh:mm:ss`), so the line layout does not matter. An
entry is new when it is newer than the newest one seen last time (or at
that time stamp beyond the number seen there); a log whose newest entry
is older than the last one seen was reset and becomes a new baseline.
Each new entry is matched against
`/etc/xymon/my-xymon-extensions-server/fritzbox-log.rules`
(`category color pattern`, first match wins; see the comments in the
file). The shipped rules cover the German messages seen on the
reference box: the daily reconnect, connection established/lost, IPv6
prefix (green, only counted) and failed internet telephony (yellow).
Everything else is **unmatched and yellow**, so Xymon records it in the
column history - add a rule for it, and it is classified from then on.
The status lists the newest FRITZBOX_LOG_SHOW (20) entries; only new
ones carry a color icon. A text longer than 300 bytes is cut there,
never inside a UTF-8 character. FRITZBOX_MASK=1 hides IP addresses,
prefixes and long numbers, before the cut. The box writes its log in the language of its user
interface; the patterns stay ASCII (an umlaut is matched by `.*`).

**fritzfw** - the port mappings of the WAN connection that is up
(GetPortMappingNumberOfEntries, GetGenericPortMappingEntry), compared as
`PROTOCOL:EXTPORT:CLIENT:INTPORT` (enabled mappings only), plus the
settings `upnp` (X_AVM-DE_UPnP), `upnp_portmapping` (IGD: devices may
open ports themselves), `remote_access`/`remote_port`/`letsencrypt`
(X_AVM-DE_RemoteAccess), `dyndns` and its IPv4/IPv6 status, `myfritz`
and `myfritz_registered`. IPv6 port sharing (pinholes) is not visible
over TR-064. A failed settings query warns and keeps the previous
baseline (a missing setting is not a change); the mapping count is still
reported when the mapping list itself was read completely.

**fritzlan** - LANEthernetInterfaceConfig GetInfo/GetStatistics (64-bit
byte counters; "to LAN" is what the box sent into the LAN) and the host
list: `X_AVM-DE_GetHostListPath` returns a session URL that delivers all
hosts in one download instead of one request per host. Counted are
known and active hosts, the active ones per interface type (Ethernet,
802.11, HomePlug, other) and active guests. The status shows counts
only, no host names. FRITZBOX_LAN_REQUIRED="MAC[=label] ..." lists
devices that must be active (`-` or `:` as separator). The new-MAC
check is off by default: phones and virtual machines often use random
MAC addresses (second hex digit 2, 6, A or E).

**fritztel** - `X_AVM-DE_GetVoIPAccounts` (the account list, without
passwords) and `X_AVM-DE_GetVoIPStatus` per account. The documented
values ([TR-064_VoIP.pdf](https://fritz.support/resources/TR-064_VoIP.pdf),
table 53) are `disabled`, `not registered`, `registered`, `connected`
(a call is active) and `unknown`: registered and connected are green, a
disabled account is listed but neither counted nor an alarm (it is
switched off on purpose), anything else is red. If the per-account
action is unavailable, the list's status is used. The documentation
shows text there; the reference box (FRITZ!OS 8.26) sends `2` for a
registered account instead, which is accepted - no other number is
interpreted, as no code table is documented. A failed account-list
query yields unknown counts, never a fabricated zero. DECT handsets
(`X_AVM-DE_Dect`) are listed for information: connected while their
`Active` flag is 1, "currently not connected" while it is 0
([TR-064_DECT.pdf](https://fritz.support/resources/TR-064_DECT.pdf),
chapter 5). Missing or invalid `Active` values are shown as "connection
state unknown"; this informational field never changes the column color.

**plc** - `X_AVM-DE_Homeplug` GetNumberOfDeviceEntries and
GetGenericDeviceEntry: MAC (the adapter's PLC MAC), active, name, model,
update available, last update result. Written atomically to
`$XYMONVAR/fritzbox/<host>.homeplug` by every poll that reads the list
(also when the Xymon delivery fails, never in a dry run):

```
# fritzbox homeplug fritz.box 1792275201
F0:B0:14:00:00:01|1|0|failed|FRITZ!Powerline 1220E|Upstairs
```

powerline.sh reads these files and adds the box's view to each
adapter's powerline column; this module has no column of its own.
An incomplete enumeration leaves the previous file aging. Indexed
enumerations are capped at 32 entries to protect the run budget; a
truncated port mapping list warns, keeps its previous baseline and
reports an unknown mapping count instead of a partial total.

The input arguments `NewIndex` for HomePlug/DECT and
`NewVoIPAccountIndex` for SIP status are documented by FRITZ! (the
official page <https://fritz.com/en/pages/interfaces> links these
PDFs on fritz.support):
[HomePlug](https://fritz.support/resources/TR-064_HomePlug.pdf),
[DECT](https://fritz.support/resources/TR-064_DECT.pdf),
[VoIP](https://fritz.support/resources/TR-064_VoIP.pdf).

## Graphs

All RRDs come from native `data HOST.trends` messages: one file per
metric, `<column>,<name>.rrd` with the single dataset `lambda`. After a
failed poll, the RRDs of the last clean one get an explicit U, so an
outage is a gap and never a bridged or zero value. fritzdsl and fritzwan
write the files of the former split-NCV extensions (same names, same
types: the fritzdsl error counters are DERIVE, everything else GAUGE),
so their history continues; new are `fritzdsl,atuc_crc|fec|hec.rrd`
(far end), `fritzdsl,reconnect.rrd`, `fritzwan,link_up|connected.rrd` and
`fritzwan,pps_down|pps_up.rrd`.
fritzlog writes one file per rules category plus `unmatched` (new
entries per poll; U on a baseline).

| Column | Status page graphs (GRAPHS_<column>) |
|--------|--------------------------------------|
| fritzdsl | sync and attainable rate, noise margin, attenuation, CRC errors/minute, FEC corrections/second, HEC errors/minute (each near and far end), errored seconds/hour, WAN connection uptime in hours (every drop is a new connection), DSL resyncs and WAN reconnects as marks with their count |
| fritzwan | throughput with the volume in GiB for the shown period, packets per second, link and internet connection 1/0 with availability in %, utilization, link capacity |
| fritzsys | uptime, clock offset |
| fritzlog | new entries per category |
| fritzfw | port mappings |
| fritzlan | throughput, host counts |
| fritztel | SIP accounts |

The drop-ins `/etc/xymon/xymonserver.d/{fritzdsl,fritzwan,fritzbox}.cfg`
add the columns to TEST2RRD without a handler - so svcstatus.cgi shows
their graphs and the status text is never NCV-parsed - and list the
graphs (GRAPHS, GRAPHS_<column>); `/etc/xymon/graphs.d/` holds the
definitions. Two rules of Xymon 4.3 (read in its sources) shape them:

- The status page draws GRAPHS_<column> only if GRAPHS has an entry
  named like the column's TEST2RRD name (`lib/htmllog.c`); without one
  it draws nothing. Up to 0.29.0 fritzdsl and fritzwan lacked it, so
  their status pages had no graphs.
- The trends page puts every file `<column>,*.rrd` under that entry and
  draws the graph of the same name (`web/svcstatus-trends.c`), split
  into pictures of at most 5 files unless the entry says `::N`. Where
  that graph draws only some of the files (fritzdsl, fritzwan,
  fritzsys, fritzlan), `::99` keeps them in one picture - split, every
  picture but the first stayed empty.

The status text carries the same values a second time, as a hidden
block that Xymon's NCV parser can read (`xymond/rrd/do_ncv.c`) however
the visible text changes: the visible part sits between
`<!-- ncv_skipstart -->` and `<!-- ncv_skipend -->`, then follow the
values as `name : value` lines (the RRD names; unknown values left out)
inside an HTML comment, and `<!-- ncv_end -->` closes it. Nothing reads
the block today; it keeps a switch to NCV (`TEST2RRD+=",<column>=ncv"`
with a `SPLITNCV_<column>`) open without depending on the layout. Such
a switch writes the same RRD files as the trends messages, so it only
makes sense together with dropping those.

## Settings

All settings live in `fritzbox.cfg` and can be overridden by the
environment or `--set KEY=VALUE` (CLI > environment > config >
defaults). `fritzbox.sh --help` lists them all with their defaults.
Frequently used:

| Setting | Default | Meaning |
|---------|---------|---------|
| FRITZBOX_ENABLED | 0 (shipped) | 1 = poll |
| FRITZBOX_TAG | fritzbox | hosts.cfg tag of the boxes; `--host NAME` instead |
| FRITZBOX_MODULES | dsl wan sys log fw lan tel plc | modules to run |
| FRITZBOX_PASSFILE | .../fritz.passwd | password file (fritz-wifi format) |
| FRITZBOX_USER | (password file) | TR-064 user for every box |
| FRITZBOX_HOLD_MINUTES | 60 | how long a reboot, a log entry, a change keeps its color |
| FRITZBOX_MASK | 0 | 1 = mask addresses and numbers in fritzlog/fritztel |
| FRITZBOX_LIFETIME | 15 | status lifetime in minutes |
| FRITZBOX_RUN_BUDGET | 180 | seconds for network requests (task MAXTIME 4m) |

`--ask-password` prompts once (for a manual run with `--host`);
`FRITZPASSWORT` in the environment is used for every host and removed
before curl runs. `--debug` prints the raw answers with session IDs
masked.

## Migration from the fritzdsl and fritzwan client extensions

Up to 0.28 fritzdsl and fritzwan were client extensions with their own
configs. They left the client packages; the Debian client package
removes their files and launch snippets (an edited config stays as
`.dpkg-bak` next to the old place). The server package breaks client
packages older than 0.29.0, so on a host with both the two are upgraded
together and no column gets two senders. To carry the setup over:

| Old (fritzdsl.cfg / fritzwan.cfg) | New |
|-----------------------------------|-----|
| FRITZ_HOST, REPORTHOST | the host in hosts.cfg with the tag `fritzbox` |
| FRITZ_USER, FRITZ_PASSWORD, FRITZ_PASSWORD_FILE | a line in fritz.passwd |
| FRITZ_PORT, TIMEOUT, CURL | FRITZBOX_PORT, FRITZBOX_MAX_TIME, FRITZBOX_CURL |
| MARGIN_WARN, MARGIN_CRIT | FRITZBOX_DSL_MARGIN_WARN, FRITZBOX_DSL_MARGIN_CRIT |
| CRC_RATE_WARN, CRC_RATE_CRIT | FRITZBOX_DSL_CRC_WARN, FRITZBOX_DSL_CRC_CRIT |
| WAN_SERVICE | FRITZBOX_DSL_WAN_SERVICE |
| MODE (fritzwan) | FRITZBOX_WAN_MODE |
| UTIL_WARN, UTIL_CRIT | FRITZBOX_WAN_UTIL_WARN, FRITZBOX_WAN_UTIL_CRIT |

The RRD files stay. After the upgrade to 0.29.1 the status pages of
fritzdsl and fritzwan show their graphs, without a restart: the
drop-ins are already in the include lists, and the CGIs read the
configuration on every call.
Two visible changes: fritzwan's `maxbps_*` (and so
the utilization) now uses the IGD link capacity when available - one
step down in that graph - and xymonserver.d/fritzdsl.cfg and
fritzwan.cfg no longer name the `ncv` handler.

## References and test scope

- AVM TR-064 documentation: <https://fritz.com/service/schnittstellen/>
  (first steps, SCPD descriptions per service)
- [Native trends parser](https://github.com/xymon-monitoring/xymon/blob/master/xymond/rrd/do_trends.c)
- `tests/fritzbox/run.sh` replays anonymized answers of the reference
  box (derived from a read-only crawl) through a fake curl: every
  column, the hold and baseline logic, counter width and reset, the log
  rules including unmatched entries, the password file rules, failures,
  dry run and the lock. Not tested against other models.
