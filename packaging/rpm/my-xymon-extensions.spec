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

%prep
%setup -q

%install
sh packaging/common/stage.sh "%{buildroot}" \
    "%{xymonhome}/ext" \
    "%{xymonhome}/etc" \
    "%{_docdir}/%{name}"

%files
%{xymonhome}/ext/smart.sh
%config(noreplace) %{xymonhome}/etc/smart.cfg
%dir %{xymonhome}/etc/tasks.d
%config(noreplace) %{xymonhome}/etc/tasks.d/smart.cfg
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
EOF

%changelog
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
