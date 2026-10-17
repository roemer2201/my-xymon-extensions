# FRITZ!Box server collector - approved implementation plan

## Scope and environment

A server-side POSIX sh collector `fritzbox` (Xymon server task via
tasks.d, like powerline and fritz-wifi) that polls AVM FRITZ!Box routers
over TR-064 (and UPnP/IGD where noted) and reports several columns per
box. Reference device: FRITZ!Box 7510 (1&1 branding), FRITZ!OS 8.26
(271.08.26), VDSL 35b over PPPoE, TR-064 on HTTP port 49000. Server
package only (my-xymon-extensions-server, Debian/Ubuntu), installed to
/usr/lib/xymon/server/ext/. Branch `claude/fritzbox-tr064-columns`, based
on current main. Version 0.29.0.

The existing client extensions fritzdsl and fritzwan move into this
collector (they leave every client package, including opkg/standalone).
The powerline collector gains a FRITZ!Box view of its adapters and an
"occasional adapter" mode.

## Findings the design rests on

All from a read-only crawl of the reference box (every Get action
without input arguments, index loops capped at 5):

- One login (HTTP digest) per request; `curl --digest --ntlm` and an
  action element with its own closing tag work on the box (the same
  rules fritz-wifi needed for the 1260E).
- Since FRITZ!OS 7.24 a TR-064 user name is always required.
- TR-064 `WANCommonInterfaceConfig GetTotalBytes*` are 64-bit on
  FRITZ!OS 8.26 (191423805702 > 2^32); fritzwan assumed 32 bit there.
- IGD `GetCommonLinkProperties` reports 233.094/45.486 Mbit/s, which is
  `max_ds * 8` of the box's online monitor; TR-064 reports the
  attainable DSL rate (268.304/47.361 Mbit/s). The online monitor
  arrays `*_current_bps` are bytes/s despite their name.
- `X_AVM-DE_Homeplug` lists adapters with MACAddress (= the PLC MAC the
  powerline collector uses), Active, Name, Model, UpdateAvailable,
  UpdateSuccessful. No rates.
- `DeviceInfo GetDeviceLog` returns the event log as text, entries
  `dd.mm.yy hh:mm:ss message`, newest first, German UI language.
  Observed message types: forced-disconnect prevention, internet
  connection lost/established (IPv4/IPv6), IPv6 prefix obtained/updated,
  "Internettelefonie mit ... war nicht erfolgreich".
- `X_VoIP X_AVM-DE_GetVoIPAccounts` lists accounts (index, registrar,
  number, status code) without passwords; `X_AVM-DE_GetVoIPStatus`
  (input NewVoIPAccountIndex) returns "registered". `GetVoIPAccount`
  and `GetClient*` return passwords and are never called.
- `X_AVM-DE_GetHostListPath` returns a session URL; one GET on port
  49000 returns all hosts (84 on the reference box) as `<Item>` blocks
  with MACAddress, Active, InterfaceType, X_AVM-DE_Guest, X_AVM-DE_Port,
  X_AVM-DE_Speed, ...
- `LANEthernetInterfaceConfig GetStatistics` byte counters are 64-bit.
- Remote access fields: X_AVM-DE_RemoteAccess GetInfo (Enabled, Port,
  LetsEncryptEnabled, LetsEncryptState), GetDDNSInfo (Enabled,
  StatusIPv4, StatusIPv6), X_AVM-DE_MyFritz GetInfo (Enabled,
  DeviceRegistered, State, Port). User names, domains and e-mail
  addresses are never read into a status.
- Xymon keeps exactly one status per host and column; a second sender
  would overwrite it. Data for the powerline column must therefore pass
  through powerline.sh.

## Collector `fritzbox.sh`

- One task, one lock, one run budget; per box: tr64desc.xml and
  igddesc.xml once, then the enabled modules. Boxes are the hosts.cfg
  hosts tagged `fritzbox` (FRITZBOX_TAG) or `--host NAME`.
- Credentials: the fritz-wifi password file format and permission rules
  (`host_or_ip user password`), same default path, so one file serves
  both collectors. Passwords reach curl only on stdin.
- Modules (FRITZBOX_MODULES, default all): `dsl` -> fritzdsl,
  `wan` -> fritzwan, `sys` -> fritzsys, `log` -> fritzlog, `fw` -> fritzfw,
  `lan` -> fritzlan, `tel` -> fritztel, `plc` -> no column, writes the
  homeplug hand-over file. A module whose service is missing on a box
  reports clear.
- Settings: defaults < config < environment < CLI (`--set`), --help,
  --version, --silent/--verbose, --debug, --dry-run, --ask-password;
  syslog logging like fritz-wifi. Shipped disabled
  (FRITZBOX_ENABLED=0).
- Delivery: one status per column with a 15-minute lifetime; RRD values
  as native `data HOST.trends` messages (explicit U on failure). No
  TEST2RRD handler, so status texts are never NCV-parsed.
- Unreachable box: every enabled column red; refused login: yellow.

## Columns

- fritzdsl: as before (state, rates, margins, attenuation, error
  counters, CRC rate, WAN uptime) plus far-end (ATU-C) CRC/FEC/HEC
  counters and VDSL profile/modulation in the text. Same RRD file names
  and DS types as the NCV version (fritzdsl,<name>.rrd, DS lambda), so
  history continues. Transmit power is left out (unit unknown).
- fritzwan: as before; IGD 64-bit counters preferred, TR-064 counters
  with width detection (64 once any value >= 2^32; a 32-bit wrap is
  corrected only when the previous value was above 2^31, else it is a
  reset). Link capacity and utilization from IGD when available, TR-064
  otherwise (maxbps_* steps down once).
- fritzsys: model, firmware, uptime, update available (yellow), last
  update result (note; yellow optional), reboot (yellow for
  FRITZBOX_HOLD_MINUTES), clock offset box vs. server from
  `Time GetInfo` (yellow > 60 s, red > 300 s), NTP servers.
  RRD: uptime, clock_offset.
- fritzlog: new entries since the last poll, matched against a rules
  file (`category color ERE`, ASCII-only patterns). Shipped rules cover
  only the observed message types. Unmatched entries are yellow, so
  Xymon records them and rules can be added later. A non-green event
  keeps the column at its color for FRITZBOX_HOLD_MINUTES (60). The first
  poll is a baseline. Last FRITZBOX_LOG_SHOW (20) entries in the text;
  FRITZBOX_MASK=1 masks addresses and numbers. RRD: events per category
  per poll.
- fritzfw: port mappings of the active WAN connection (PPP or IP),
  UPnP and "allow changes by applications", remote access, MyFRITZ,
  DynDNS status. With FRITZBOX_FW_EXPECTED a mapping not listed or a
  listed one missing is yellow; without it the first poll is the
  baseline and every change is yellow for FRITZBOX_HOLD_MINUTES. IPv6
  pinholes are not visible over TR-064 (documented). RRD: mapping count.
- fritzlan: LAN throughput from the 64-bit counters (average since the
  last poll), host counts from the host list: total, active, active per
  interface type, active guests. Optional FRITZBOX_LAN_REQUIRED (MACs
  that must be active, yellow or red) and FRITZBOX_LAN_NEW_MAC (warn on
  unknown MACs, default off: randomized MACs). No per-host list in the
  status. RRD: bps_rx, bps_tx, host counts.
- fritztel: SIP accounts from GetVoIPAccounts plus GetVoIPStatus per
  account; not registered is red, no account is clear. DECT handsets
  as information only. RRD: sip_total, sip_registered.

## Powerline collector changes

- FRITZ!Box view: fritzbox.sh writes `<box>.homeplug` into its state
  dir; powerline.sh reads POWERLINE_FRITZBOX_DIR (default
  XYMONVAR/fritzbox, missing directory = feature off) and adds one line
  per adapter matched by PLC MAC: name, model, active, firmware update.
  Update available: yellow. Last update failed: note (yellow with
  POWERLINE_FRITZBOX_UPDATE_FAILED=yellow). Box says inactive, no entry,
  stale file (POWERLINE_FRITZBOX_MAX_AGE, 900 s): note only.
- Occasional adapters: optional third field `occasional` in
  powerline.map. Appearing/disappearing is yellow for
  POWERLINE_CHANGE_MINUTES, never escalates to "state flapping", is
  never forgotten (no purple), absent shows green "not plugged in
  (occasional adapter)". A peer whose change is caused only by an
  occasional adapter is treated the same way.
- Clearer change texts for all adapters: new adapter detected, adapter
  disappeared, adapter back, peer added/lost.

## Packaging and migration

- Server package: fritzbox.sh, fritzbox.cfg, fritzbox-log.rules,
  tasks.d/fritzbox.cfg, graphs.d and xymonserver.d drop-ins per column
  (fritzdsl/fritzwan keep their file names; their xymonserver.d drops
  the NCV handler).
- Client packages (deb, rpm, FreeBSD, opkg) and standalone drop fritzdsl
  and fritzwan; the deb removes the old conffiles with rm_conffile
  (edited files are kept as .dpkg-bak), the others document it.
- CLAUDE.md, README, packaging docs and changelogs follow.

## Tests

- tests/fritzbox: fake curl answering by SOAP action and URL from
  anonymized fixtures derived from the reference crawl (documentation
  addresses, locally administered MACs, invented names and numbers).
- Cases per module (green, each warning, failures, baseline/hold logic,
  log rules incl. unmatched, counter width/reset, password file rules)
  and for the powerline changes. `make test` must pass; shellcheck and
  BusyBox/dash runs as for the other collectors.
