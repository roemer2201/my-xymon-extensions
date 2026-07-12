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
%{xymonhome}/ext/opkg.sh
%config(noreplace) %{xymonhome}/etc/smart.cfg
%config(noreplace) %{xymonhome}/etc/temp.cfg
%config(noreplace) %{xymonhome}/etc/la.cfg
%config(noreplace) %{xymonhome}/etc/memory.cfg
%config(noreplace) %{xymonhome}/etc/opkg.cfg
%dir %{xymonhome}/etc/tasks.d
%config(noreplace) %{xymonhome}/etc/tasks.d/smart.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/temp.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/la.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/memory.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/opkg.cfg
%{xymonhome}/ext/fritzdsl.sh
%config(noreplace) %{xymonhome}/etc/fritzdsl.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/fritzdsl.cfg
%{xymonhome}/ext/fritzwan.sh
%config(noreplace) %{xymonhome}/etc/fritzwan.cfg
%config(noreplace) %{xymonhome}/etc/tasks.d/fritzwan.cfg
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
EOF

%changelog
* Sun Jul 12 2026 roemer2201 <r.oliver@web.de> - 0.8.0-1
- opkg: new extension - pending package update monitoring for
  opkg-based systems (OpenWrt/TurrisOS): refreshes the package lists
  itself when they are missing or stale (they live in RAM on
  OpenWrt), yellow on available updates, red when an update matches
  a configurable list of security-relevant package patterns, clear
  where opkg does not exist; NCV lines for RRD graphing; the task
  snippet ships disabled on full clients

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
