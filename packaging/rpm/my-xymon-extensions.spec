# RPM spec for my-xymon-extensions.
#
# Default layout matches the Terabithia xymon-client builds
# (XYMONHOME=/usr/lib64/xymon/client). Override at build time for other
# layouts, e.g.:
#   rpmbuild ... --define 'xymonhome /usr/share/xymon-client'
%{!?xymonhome: %global xymonhome /usr/lib64/xymon/client}

Name:           my-xymon-extensions
Version:        %{?pkgver}%{!?pkgver:0.0.0}
Release:        1%{?dist}
Summary:        Portable Xymon client extensions
License:        TBD
URL:            https://github.com/roemer2201/my-xymon-extensions
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch
Requires:       smartmontools
Recommends:     curl
# "xymon-client" matches the Terabithia and EPEL package names;
# rebuild with --define 'xymonclientpkg <name>' for other builds.
%{!?xymonclientpkg: %global xymonclientpkg xymon-client}
Requires:       %{xymonclientpkg}

%description
Custom monitoring tests (extensions) for the Xymon systems monitor.

Included extensions:
* smart - S.M.A.R.T. disk health monitoring for SATA/ATA, NVMe and
  basic SAS disks, plus eMMC wear/pre-EOL health (via mmc-utils),
  with vendor-normalized metrics, thresholds and per-disk RRD
  graphing support.
* temp - all hardware temperature sensors from the Linux
  hwmon/thermal sysfs, per-sensor thresholds and RRD graphing.
* la - load average with per-CPU-core thresholds (task disabled by
  default: the Xymon client already covers this on full clients).
* memory - memory utilization in percent (task disabled by default:
  the Xymon client already covers this on full clients).
* disk - filesystem usage from df with global and per-mount
  thresholds, reporting into the standard "disk" column for
  clientless hosts (task disabled by default: the Xymon client
  already covers this on full clients).
* opkg - pending package updates on opkg-based systems
  (OpenWrt/TurrisOS; task disabled by default: hosts with a full
  Xymon client have no opkg).
* fritzdsl - AVM FRITZ!Box DSL line monitoring via TR-064 (curl):
  line state, sync rate, noise margin, attenuation and error counters
  with thresholds and RRD graphing support; polls the box from the
  Xymon server, no software on the box.
* fritzwan - AVM FRITZ!Box WAN throughput monitoring (curl): physical
  link state, average throughput, link capacity and utilization from
  the box's 64-bit UPnP counters (TR-064 fallback), with optional
  utilization thresholds and RRD graphs.
* wifi - Wi-Fi access point metadata via iw/nl80211 (task disabled by
  default: full clients are rarely APs): client counts, channel
  utilization, airtime, throughput, TX retries and noise floor with
  RRD graphing; informational only.
* if_link - network interface link state changes from the kernel's
  carrier counters: counts every link down/up transition per port,
  including short flaps between two polls, with optional per-port
  thresholds and RRD graphs; Linux-only, green until thresholds are
  configured.
* xymonext - what the extensions above cost this host: wall clock
  time, CPU time and the number of bytes each test sends to the
  Xymon server, measured on every run and reported in one
  "xymonext" column with RRD graphs per test. The tasks.d snippets
  call the extensions through its wrapper; measuring can be turned
  off in xymonext.cfg.

%prep
%setup -q

%install
sh packaging/common/stage.sh "%{buildroot}" \
    "%{xymonhome}/ext" \
    "%{xymonhome}/etc" \
    "%{xymonhome}/etc/tasks.d" \
    "%{_docdir}/%{name}"

%files
%{xymonhome}/ext/smart.sh
%{xymonhome}/ext/temp.sh
%{xymonhome}/ext/la.sh
%{xymonhome}/ext/memory.sh
%{xymonhome}/ext/disk.sh
%{xymonhome}/ext/opkg.sh
%config(noreplace) %{xymonhome}/etc/smart.cfg
%config(noreplace) %{xymonhome}/etc/temp.cfg
%config(noreplace) %{xymonhome}/etc/la.cfg
%config(noreplace) %{xymonhome}/etc/memory.cfg
%config(noreplace) %{xymonhome}/etc/disk.cfg
%config(noreplace) %{xymonhome}/etc/opkg.cfg
%dir %{xymonhome}/etc/tasks.d
%config(noreplace) %{xymonhome}/etc/tasks.d/smart.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/temp.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/la.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/memory.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/disk.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/opkg.cfg
%{xymonhome}/ext/fritzdsl.sh
%config(noreplace) %{xymonhome}/etc/fritzdsl.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/fritzdsl.cfg
%{xymonhome}/ext/fritzwan.sh
%config(noreplace) %{xymonhome}/etc/fritzwan.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/fritzwan.cfg
%{xymonhome}/ext/wifi.sh
%config(noreplace) %{xymonhome}/etc/wifi.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/wifi.cfg
%{xymonhome}/ext/if_link.sh
%config(noreplace) %{xymonhome}/etc/if_link.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/if_link.cfg
%{xymonhome}/ext/xymonext.sh
%{xymonhome}/ext/xymonext-send.sh
%config(noreplace) %{xymonhome}/etc/xymonext.cfg
%{_docdir}/%{name}/

%post
cat <<'EOF'
my-xymon-extensions: to activate the "smart" extension:
 1. Grant the xymon user access to smartctl - see
    %{_docdir}/%{name}/smart/sudoers.example
 2. Make sure clientlaunch.cfg loads the tasks.d directory
    (add this line once if it is missing):
      directory %{xymonhome}/etc/tasks.d
 3. Restart the Xymon client service.
The FRITZ!Box extensions "fritzdsl" and "fritzwan" ship disabled:
 configure %{xymonhome}/etc/fritzdsl.cfg resp. fritzwan.cfg, then
 remove the DISABLED line from the matching tasks.d snippet and
 restart the client on the polling host (normally the Xymon server).
The "wifi" extension ships disabled too: enable it (remove the
 DISABLED line from the tasks.d snippet) only on a Linux access
 point with iw installed.
The "if_link" extension (link state changes per network interface)
 is active out of the box and adds an "if_link" column. It stays
 green until you configure thresholds in %{xymonhome}/etc/if_link.cfg.
Every task now runs through %{xymonhome}/ext/xymonext.sh, which
 measures the extension and adds an "xymonext" column with runtime,
 CPU time and traffic per test. Set XYMONEXT_ENABLE="no" in
 %{xymonhome}/etc/xymonext.cfg to run the extensions directly again.
RRD graphs need a one-time setup on the Xymon SERVER (not here):
 ready-made drop-in files for its xymonserver.d, graphs.d and
 rrddefinitions.d directories ship in
 %{_docdir}/%{name}/<extension>/server/ - copy them over and restart
 Xymon there; see the README.md next to them.
EOF

%changelog
* Mon Aug 10 2026 roemer2201 <r.oliver@web.de> - 0.13.0-1
- server side: ship every extension's Xymon server configuration as
  drop-in files instead of instructions to edit stock config files.
  Xymon reads all of its config files through one reader
  (lib/stackio.c), so "include", "directory" and "optional" work in
  every one of them - verified in the sources for graphs.cfg
  (load_gdefs, web/showgraph.c), rrddefinitions.cfg (load_rrddefs,
  xymond/xymond_rrd.c) and xymonserver.cfg (loadenv, lib/environ.c),
  none of which is documented in the manual. The TEST2RRD/NCV/GRAPHS
  settings of every extension now live in
  server/xymonserver.d/<name>.cfg, matching the existing
  server/graphs.d and server/rrddefinitions.d layout; temp, la, memory
  and opkg gained a server/ directory (their settings were prose in
  the client README before). Documentation only on the client side -
  no extension script changed. New consistency test: stage.sh installs
  every server-side file and the FreeBSD pkg-plist lists exactly the
  staged set

* Mon Aug 10 2026 roemer2201 <r.oliver@web.de> - 0.12.0-1
- xymonext: new extension - measures what the client extensions cost
  the host. A wrapper runs each extension unchanged and records its
  wall clock time (/proc/uptime, /usr/bin/time -p on FreeBSD), the
  CPU time of the whole process tree (the POSIX "times" builtin, so
  no external tool is needed) and the number of bytes it sent to the
  server (a shim in front of $XYMON). One "xymonext" column carrying
  the table of all measured tests, split-NCV RRD graphs per test and
  metric, thresholds on the wall clock time to catch a hanging test;
  the tasks.d snippets and the standalone runner call the extensions
  through the wrapper, which can be switched off in xymonext.cfg

* Mon Aug 10 2026 roemer2201 <r.oliver@web.de> - 0.11.2-1
- smart: make the two DWPD graphs readable. A lifetime DWPD of 0.0034 is
  a normal value, and with rrdtool's defaults the y-axis of the smartdwpd
  and smartdwpdrecent graphs came out labelled "3.0 m" to "4.0 m" (milli)
  and autoscaled to the data range, so a drift of three ten-thousandths
  filled the whole graph and looked alarming. The two blocks in
  server/graphs.d/smart.cfg now set -X 0 (fix the SI exponent, plain
  decimals instead of an "m" prefix), -L 6 (room for labels like 0.004),
  -l 0 (anchor at zero, so the height shows the true magnitude) and -Y
  (alternative y-grid for the resulting narrow range). Graph definitions
  only - no change to the extension or its metrics

* Mon Aug 10 2026 roemer2201 <r.oliver@web.de> - 0.11.1-1
- if_link: stop long-range graphs from diluting single link changes
  into fractions. The extension only ever sends whole numbers, but
  Xymon creates RRD files with AVERAGE archives only, so a graph longer
  than 48 hours divides a flap by the consolidation factor of the view:
  a measured 2-change flap was drawn as 0.39 over 5 days, 0.20 over 12
  days and 0.07 over 40 days. New server-side archive definition
  (server/rrddefinitions.d/if_link.cfg) adds MAX archives next to
  Xymon's default AVERAGE ones, and the graph now draws its line from
  MAX - same visible height in every time range - plus an exact
  "(total)" event count for the shown window, integrated from the
  AVERAGE archive. Note that the per-slot values stay fractional and
  cannot be made whole: RRDtool aligns its 5-minute grid to the epoch,
  so a poll at a fixed offset inside the grid has every value split
  across two slots (2 changes -> 1.33 + 0.67 at an offset of 100 s).
  The dataset type therefore stays GAUGE - ABSOLUTE would store a rate
  per second and make the raw values less readable without fixing this.
  Existing installations have to drop their if_link RRD files once,
  since rrddefinitions.cfg is only consulted when a file is created;
  the client script is unchanged

* Sun Aug 09 2026 roemer2201 <r.oliver@web.de> - 0.11.0-1
- if_link: new extension - network interface link state changes from
  the kernel's carrier_changes counter (fallback: carrier_up_count +
  carrier_down_count), so even flaps that start and end between two
  polls are counted; dynamic interface discovery (physical Ethernet
  ports including DSA switch ports, with glob-based include/exclude
  lists and switches for wireless and virtual devices), green by
  default with optional global and per-port thresholds, split-NCV RRD
  graphing; active out of the box (it needs nothing but sysfs) and in
  the default TESTS list of the standalone runner

* Tue Jul 28 2026 roemer2201 <r.oliver@web.de> - 0.10.4-1
- temp: keep implausible sensor readings out of the RRD. Values
  outside TEMP_PLAUSIBLE_MIN..MAX were already reported as "clear"
  and left out of the NCV comment block, but the server's NCV parser
  treats "=" like ":" and so picked the bogus value up from the
  human-readable "&clear NAME = 491.0 C" line anyway. That whole part
  of the status message is now fenced off with the parser's
  ncv_skipstart/ncv_skipend markers, which also stops the normal
  display lines from creating a duplicate RRD dataset each

* Tue Jul 28 2026 roemer2201 <r.oliver@web.de> - 0.10.3-1
- disk: stop the Xymon server from creating bogus filesystem RRDs.
  The table header no longer says "Filesystem": that word made the
  server's disk RRD handler use the Windows format and name the RRD
  after the device column, so hosts whose first df row is a tmpfs or
  an overlay (OpenWrt) got "disk,tmpfs.rrd" instead of
  "disk,tmp.rrd". Footer notes and the "clear" messages are now
  prefixed with "&clear", the only reliable way to keep a line that
  contains a "/" out of that handler - short notes were still picked
  up and produced a nameless "disk.rrd" (and, before, "disk(,dev.rrd")

* Tue Jul 14 2026 roemer2201 <r.oliver@web.de> - 0.10.2-1
- disk: new extension - filesystem usage from "df -P -k" for
  clientless hosts (standalone runner), reporting into the standard
  "disk" column: global and per-mount thresholds, configurable
  exclude globs (/dev and /rom hidden by default), df-style table in
  the status parsed by the Xymon server's built-in disk RRD handler
  (stock graphs, no server-side setup); the task snippet ships
  disabled on full clients, which report "disk" themselves

* Mon Jul 13 2026 roemer2201 <r.oliver@web.de> - 0.9.0-1
- opkg: new extension - pending package update monitoring for
  opkg-based systems (OpenWrt/TurrisOS): refreshes the package lists
  itself when they are missing or stale (they live in RAM on
  OpenWrt), yellow on available updates, red when an update matches
  a configurable list of security-relevant package patterns, clear
  where opkg does not exist; NCV lines for RRD graphing; the task
  snippet ships disabled on full clients

* Sun Jul 12 2026 roemer2201 <r.oliver@web.de> - 0.8.0-1
- wifi: new extension - Wi-Fi access point metadata via iw/nl80211
  and (on OpenWrt) ubus/hostapd and iwinfo: client counts per SSID
  interface, channel utilization and noise floor per radio, interface
  throughput, client airtime and TX retry/failure rates computed from
  a state file between polls; informational only (green/clear),
  split-NCV RRD graphing; task snippet ships disabled on full clients

* Sat Jul 11 2026 roemer2201 <r.oliver@web.de> - 0.5.0-1
- fritzdsl: new extension - AVM FRITZ!Box DSL line monitoring via
  TR-064 (curl): line state, sync rate, noise margin, attenuation
  and error counters with thresholds, CRC-rate check and split-NCV
  RRD graphing; ships disabled until credentials are configured
- fritzwan: new extension - AVM FRITZ!Box WAN throughput monitoring:
  physical link state, average throughput, link capacity and
  utilization computed from the box's 64-bit UPnP byte counters
  (TR-064 32-bit fallback with wrap correction), optional
  utilization thresholds, split-NCV RRD graphing; ships disabled
  until configured

* Sat Jul 11 2026 roemer2201 <r.oliver@web.de> - 0.4.0-1
- new extensions temp, la and memory: local health metrics for
  clientless hosts (Turris Omnia / OpenWrt via the standalone runner)
  - hwmon/thermal temperature sensors, load average with per-core
  thresholds, memory utilization; NCV lines for RRD graphing; the
  la/memory task snippets ship disabled on full clients

* Fri Jul 10 2026 roemer2201 <r.oliver@web.de> - 0.3.0-1
- smart: eMMC health monitoring (Linux) via mmc-utils - EXT_CSD life
  time estimation mapped to the wear metric, PRE_EOL_INFO as health
  verdict; clear hints when mmc-utils or smartmontools are missing
  for present devices

* Thu Jul 09 2026 roemer2201 <r.oliver@web.de> - 0.2.0-1
- 0.2.0: standalone runner for clientless hosts added to the repo
  (shipped in the opkg package only; no rpm content changes)

* Mon Jul 06 2026 roemer2201 <r.oliver@web.de> - 0.1.0-1
- Initial package: smart extension (SMART disk monitoring, SATA + NVMe)
