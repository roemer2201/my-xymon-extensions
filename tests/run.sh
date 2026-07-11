#!/bin/sh
# Unit tests for the extensions and the standalone runner in this
# repository. Runs everything against canned command output - no real
# hardware, no Xymon server needed. Exit code 0 = all tests passed.
#
# TESTSH selects the shell used to run the scripts under test
# (default "sh"); CI also runs the suite with TESTSH="busybox sh".
set -u

TESTDIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$TESTDIR")
TESTSH="${TESTSH:-sh}"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

FAIL=0

expect() {
    # expect <haystack> <ERE> <description>
    if printf '%s\n' "$1" | grep -Eq "$2"; then
        echo "ok:   $3"
    else
        echo "FAIL: $3 (pattern not found: $2)"
        FAIL=1
    fi
}

expect_not() {
    if printf '%s\n' "$1" | grep -Eq "$2"; then
        echo "FAIL: $3 (unexpected pattern found: $2)"
        FAIL=1
    else
        echo "ok:   $3"
    fi
}

# ----------------------------------------------------------------------
echo "--- smart ---"
export FAKESMARTCTL="$TESTDIR/smart/fakesmartctl"
export FAKEMMC="$TESTDIR/smart/fakemmc"
export SMART_CFG="$TESTDIR/smart/smart_test.cfg"
export XYMONTMP="$TMP"
export MACHINE="testhost"
unset XYMON XYMSRV XYMONHOME 2>/dev/null || true

# shellcheck disable=SC2086  # TESTSH may be multi-word ("busybox sh")
out=$($TESTSH "$REPO/extensions/smart/smart.sh")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: smart.sh exited with $rc"
    printf '%s\n' "$out"
    exit 1
fi

# Overall color: tsda has 8 pending sectors and 3 CRC errors -> yellow
expect "$out" '^status testhost\.smart yellow ' \
    "overall status is yellow (bad sectors on tsda)"
expect "$out" '&yellow /dev/tsda: pending=8' \
    "pending sectors flagged on tsda"
expect "$out" '&yellow /dev/tsda: crc=3' \
    "CRC errors flagged on tsda"
expect "$out" '&green /dev/tssd - Samsung SSD 860 EVO 1TB - health: PASSED' \
    "tssd device line green with model and health"
expect "$out" '&green /dev/tnvme0 - Samsung SSD 980 PRO 1TB' \
    "NVMe device line green"

# Data (NCV) values - ATA disk
expect "$out" '^tsda_temp : 39$' \
    "attrmap override works: garbage 77 in 194 ignored, temp from 190 (39)"
expect "$out" '^tsda_pending : 8$'  "tsda pending extracted"
expect "$out" '^tsda_realloc : 0$'  "tsda realloc extracted"
expect "$out" '^tsda_hours : 20573$' "tsda power-on hours extracted"

# Data (NCV) values - SATA SSD (name-based mapping via drivedb names)
expect "$out" '^tssd_wear : 9$' \
    "SSD wear from Wear_Leveling_Count normalized value (100-91)"
expect "$out" '^tssd_temp : 31$'    "SSD temp from Airflow_Temperature_Cel"
expect "$out" '^tssd_written : 23288$' \
    "written normalized to GiB from Total_LBAs_Written (512-byte LBAs)"
expect_not "$out" 'tssd_[a-z]*ECC'  "unmapped attributes are not reported"

# Data (NCV) values - Kingston SSD: three attributes map to "wear"
# (177 Wear_Leveling_Count -> 9, 231 SSD_Life_Left -> 10,
# 233 Media_Wearout_Indicator -> 0, stuck at VALUE 100 on Kingston).
# The worst value must win; the optimistic reading must not mask it.
expect "$out" '&green /dev/tsdk - KINGSTON SUV500MS480G - health: PASSED' \
    "Kingston device line green with model and health"
expect "$out" '^tsdk_wear : 10$' \
    "wear is the worst of all wear-mapped attributes"
expect "$out" '^tsdk_temp : 41$'     "Kingston temp from 194"
expect "$out" '^tsdk_hours : 47708$' "Kingston power-on hours extracted"
expect "$out" '^tsdk_written : 21543$' "written from Host_Writes_GiB (already GiB)"
expect "$out" '^tsdk_read : 7410$'     "read from Host_Reads_GiB (already GiB)"

# Data (NCV) values - Kingston KC600: not in smartctl's drive database,
# so vendor attributes carry generic default names. 241/242 are labelled
# Total_LBAs_Written/_Read but actually count 32-MiB units (Silicon
# Motion controller); the real wear sits in 231 (VALUE 99 -> 1% used)
# while 177 Wear_Leveling_Count is stuck at VALUE 100. The built-in
# model-specific ID map must recover all of that.
expect "$out" '&green /dev/tsdc - KINGSTON SKC600MS512G - health: PASSED \(not in smartctl drive database\)' \
    "KC600 device line notes the missing drivedb entry"
expect "$out" '^tsdc_written : 2549$' \
    "KC600 written in GiB from 241 as 32-MiB units (81572/32)"
expect "$out" '^tsdc_read : 1191$' \
    "KC600 read in GiB from 242 as 32-MiB units (38109/32)"
expect_not "$out" '^tsdc_written : 0$' \
    "KC600 written not misread as 512-byte LBAs"
expect "$out" '^tsdc_wear : 1$' \
    "KC600 wear from attribute 231 by ID (100-99), not stuck 177"
expect "$out" '^tsdc_temp : 41$'    "KC600 temperature extracted"
expect "$out" '^tsdc_hours : 1754$' "KC600 power-on hours extracted"
expect "$out" '^tsdc_cycles : 39$'  "KC600 power cycles extracted"

# Data (NCV) values - NVMe
expect "$out" '^tnvme0_temp : 41$'      "NVMe composite temperature"
expect "$out" '^tnvme0_wear : 3$'       "NVMe Percentage Used"
expect "$out" '^tnvme0_spare : 100$'    "NVMe Available Spare"
expect "$out" '^tnvme0_hours : 8760$'   "NVMe hours (comma separator removed)"
expect "$out" '^tnvme0_mediaerr : 0$'   "NVMe media errors"
expect "$out" '^tnvme0_unsafeshut : 42$' "NVMe unsafe shutdowns"
expect "$out" '^tnvme0_written : 15784$' \
    "NVMe written in GiB from Data Units Written (1000x512 bytes)"
expect "$out" '^tnvme0_read : 22733$' \
    "NVMe read in GiB from Data Units Read"

# eMMC devices (queried with mmc-utils, not smartctl)
expect "$out" '&green /dev/tmmc0 - eMMC, MMC 5\.1 - health: Normal' \
    "healthy eMMC device line green with pre-EOL verdict"
expect "$out" '^tmmc0_wear : 10$' \
    "eMMC wear from LIFE_TIME_EST_TYP_A (0x01 -> up to 10% used)"
expect "$out" '&yellow /dev/tmmc1: eMMC pre-EOL: Warning' \
    "worn eMMC pre-EOL 0x02 flagged yellow"
expect "$out" '&yellow /dev/tmmc1: wear=80' \
    "worn eMMC wear 80 hits the WEAR_WARN threshold"
expect "$out" '^tmmc1_wear : 80$' \
    "eMMC wear is the worst of estimates A (0x08) and B (0x02)"

# Status display must not contain NCV-style "name : value" lines other
# than in the data section (they would pollute the RRDs).
expect "$out" 'pending=8' "status section uses key=value, not key : value"

# eMMC present but mmc-utils not installed: per-device clear hint,
# the column itself keeps the color of the checkable devices.
# shellcheck disable=SC2086
out=$(SMART_CFG="$TESTDIR/smart/smart_test_nommc.cfg" \
    $TESTSH "$REPO/extensions/smart/smart.sh")
expect "$out" '^status testhost\.smart green ' \
    "missing mmc-utils does not degrade the column color"
expect "$out" '&clear /dev/tmmc0: eMMC device present but mmc-utils is not installed' \
    "missing mmc-utils yields a clear hint for the eMMC device"
expect_not "$out" '^tmmc0_wear' \
    "no eMMC data without mmc-utils"

# No smartctl at all, but an eMMC device with mmc-utils (typical
# OpenWrt/TurrisOS router): the eMMC is still monitored.
# shellcheck disable=SC2086
out=$(SMART_CFG="$TESTDIR/smart/smart_test_mmconly.cfg" \
    $TESTSH "$REPO/extensions/smart/smart.sh")
expect "$out" '^status testhost\.smart green ' \
    "eMMC-only mode (no smartctl) reports green"
expect "$out" '&green /dev/tmmc0 - eMMC, MMC 5\.1 - health: Normal' \
    "eMMC checked although smartctl is missing"
expect "$out" '^tmmc0_wear : 10$' \
    "eMMC-only mode still delivers the wear metric"

# ----------------------------------------------------------------------
echo "--- temp ---"
TEMPFIX="$TESTDIR/temp"
EMPTYDIR="$TMP/empty"
mkdir -p "$EMPTYDIR"

# shellcheck disable=SC2086
out=$(TEMP_HWMON_DIR="$TEMPFIX/sys/class/hwmon" TEMP_THERMAL_DIR="$EMPTYDIR" \
    $TESTSH "$REPO/extensions/temp/temp.sh")
expect "$out" '^status testhost\.temp yellow ' \
    "overall temp status is yellow (switch sensor at 85.4 C)"
expect "$out" '&green armada_thermal_temp1 = 78\.1 C' \
    "unlabelled sensor named <chip>_tempN, millidegrees converted"
expect "$out" '&yellow mv88e6xxx_internal = 85\.4 C' \
    "labelled sensor named <chip>_<label>, flagged yellow at TEMP_WARN"
expect "$out" '&green mv88e6xxx_temp2 = 45\.2 C' \
    "second sensor of the same chip reported separately"
expect "$out" '&green mv88e6xxx_internal_2 = 44\.1 C' \
    "duplicate chip/label pair gets a numeric suffix"
expect "$out" '^armada_thermal_temp1 : 78\.1$' "temp NCV line (CPU sensor)"
expect "$out" '^mv88e6xxx_internal : 85\.4$'   "temp NCV line (switch sensor)"
expect "$out" '^mv88e6xxx_internal_2 : 44\.1$' "temp NCV line (deduplicated name)"

# shellcheck disable=SC2086
out=$(TEMP_HWMON_DIR="$TEMPFIX/sys/class/hwmon" TEMP_THERMAL_DIR="$EMPTYDIR" \
    TEMP_CRIT=85 $TESTSH "$REPO/extensions/temp/temp.sh")
expect "$out" '^status testhost\.temp red ' \
    "TEMP_CRIT from the environment turns the column red"

# shellcheck disable=SC2086
out=$(TEMP_HWMON_DIR="$TEMPFIX/sys/class/hwmon" TEMP_THERMAL_DIR="$EMPTYDIR" \
    TEMP_WARN=86 $TESTSH "$REPO/extensions/temp/temp.sh")
expect "$out" '^status testhost\.temp green ' \
    "raised TEMP_WARN turns the column green"

# shellcheck disable=SC2086
out=$(TEMP_HWMON_DIR="$TEMPFIX/sys/class/hwmon" TEMP_THERMAL_DIR="$EMPTYDIR" \
    TEMP_COLUMN=cputemp $TESTSH "$REPO/extensions/temp/temp.sh")
expect "$out" '^status testhost\.cputemp yellow ' \
    "column name is overridable via TEMP_COLUMN"

# shellcheck disable=SC2086
out=$(TEMP_HWMON_DIR="$EMPTYDIR" TEMP_THERMAL_DIR="$TEMPFIX/thermal" \
    $TESTSH "$REPO/extensions/temp/temp.sh")
expect "$out" '^status testhost\.temp green ' \
    "thermal_zone fallback used when no hwmon sensors exist"
expect "$out" '^cpu_thermal : 55\.5$' \
    "thermal zone named after its type, NCV line present"

# shellcheck disable=SC2086
out=$(TEMP_HWMON_DIR="$EMPTYDIR" TEMP_THERMAL_DIR="$EMPTYDIR" \
    $TESTSH "$REPO/extensions/temp/temp.sh")
expect "$out" '^status testhost\.temp clear ' \
    "no sensors at all reports clear, not red"

# ----------------------------------------------------------------------
echo "--- la ---"
LAFIX="$TESTDIR/la/loadavg"

# shellcheck disable=SC2086
out=$(LA_LOADAVG="$LAFIX" LA_NCPU=4 $TESTSH "$REPO/extensions/la/la.sh")
expect "$out" '^status testhost\.la green ' \
    "la status green (5-min load per core 0.30 below default 1.5)"
expect "$out" '&green load average \(1/5/15 min\)  0\.42  1\.20  0\.30' \
    "all three load values displayed"
expect "$out" '4 CPU core\(s\); the 5-min load per core is 0\.30' \
    "per-core load computed from LA_NCPU"
expect "$out" '^la1 : 0\.42$'  "la NCV line la1"
expect "$out" '^la5 : 1\.20$'  "la NCV line la5"
expect "$out" '^la15 : 0\.30$' "la NCV line la15"

# shellcheck disable=SC2086
out=$(LA_LOADAVG="$LAFIX" LA_NCPU=4 LA_WARN=0.30 \
    $TESTSH "$REPO/extensions/la/la.sh")
expect "$out" '^status testhost\.la yellow ' \
    "LA_WARN from the environment turns the column yellow (0.30 >= 0.30)"

# shellcheck disable=SC2086
out=$(LA_LOADAVG="$LAFIX" LA_NCPU=4 LA_CRIT=0.25 \
    $TESTSH "$REPO/extensions/la/la.sh")
expect "$out" '^status testhost\.la red ' \
    "LA_CRIT from the environment turns the column red"

# shellcheck disable=SC2086
out=$(LA_LOADAVG="$LAFIX" LA_NCPU=4 LA_COLUMN=load \
    $TESTSH "$REPO/extensions/la/la.sh")
expect "$out" '^status testhost\.load green ' \
    "column name is overridable via LA_COLUMN"

# shellcheck disable=SC2086
out=$(LA_LOADAVG="$TMP/no-such-loadavg" $TESTSH "$REPO/extensions/la/la.sh")
expect "$out" '^status testhost\.la clear ' \
    "unreadable load source reports clear, not red"

# ----------------------------------------------------------------------
echo "--- memory ---"
MEMFIX="$TESTDIR/memory/meminfo"

# shellcheck disable=SC2086
out=$(MEM_MEMINFO="$MEMFIX" $TESTSH "$REPO/extensions/memory/memory.sh")
expect "$out" '^status testhost\.memory green ' \
    "memory status green (50% used below default 80)"
expect "$out" '&green memory used 50\.0% \(1000 MB of 2000 MB, 1000 MB available\)' \
    "used percent and MB summary computed from MemTotal/MemAvailable"
expect "$out" '^used : 50\.0$' "memory NCV line"
expect_not "$out" 'estimated as MemFree' \
    "no estimation note when the kernel provides MemAvailable"

# shellcheck disable=SC2086
out=$(MEM_MEMINFO="$MEMFIX" MEM_WARN=50 \
    $TESTSH "$REPO/extensions/memory/memory.sh")
expect "$out" '^status testhost\.memory yellow ' \
    "MEM_WARN from the environment turns the column yellow (50.0 >= 50)"

# shellcheck disable=SC2086
out=$(MEM_MEMINFO="$MEMFIX" MEM_CRIT=45 \
    $TESTSH "$REPO/extensions/memory/memory.sh")
expect "$out" '^status testhost\.memory red ' \
    "MEM_CRIT from the environment turns the column red"

# shellcheck disable=SC2086
out=$(MEM_MEMINFO="$TESTDIR/memory/meminfo-noavail" \
    $TESTSH "$REPO/extensions/memory/memory.sh")
expect "$out" '^status testhost\.memory green ' \
    "kernel without MemAvailable still reports"
expect "$out" '^used : 65\.6$' \
    "fallback estimate MemFree+Buffers+Cached used"
expect "$out" 'estimated as MemFree \+ Buffers \+ Cached' \
    "estimation note shown when MemAvailable is missing"

# shellcheck disable=SC2086
out=$(MEM_MEMINFO="$TMP/no-such-meminfo" \
    $TESTSH "$REPO/extensions/memory/memory.sh")
expect "$out" '^status testhost\.memory clear ' \
    "missing /proc/meminfo reports clear, not red"

# shellcheck disable=SC2086
out=$(MEM_MEMINFO="$MEMFIX" MEM_COLUMN=mem \
    $TESTSH "$REPO/extensions/memory/memory.sh")
expect "$out" '^status testhost\.mem green ' \
    "column name is overridable via MEM_COLUMN"

# ----------------------------------------------------------------------
echo "--- standalone: xymon-send.sh ---"

# Fake "nc" that records its arguments and stdin instead of connecting.
SBIN="$TMP/sbin"
mkdir -p "$SBIN"
cat > "$SBIN/nc" <<'EOF'
#!/bin/sh
case "${1:-}" in -h) exit 0 ;; esac
{ echo "ARGS: $*"; cat; echo "---EOM---"; } >> "${NC_CAPTURE:?}"
EOF
chmod +x "$SBIN/nc"

export NC_CAPTURE="$TMP/capture-send"
: > "$NC_CAPTURE"
# shellcheck disable=SC2086
PATH="$SBIN:$PATH" $TESTSH "$REPO/standalone/xymon-send.sh" \
    192.0.2.1 "status foo.bar green hello"
expect "$(cat "$NC_CAPTURE")" '^ARGS: 192\.0\.2\.1 1984$' \
    "sender connects to the server on default port 1984"
expect "$(cat "$NC_CAPTURE")" '^status foo\.bar green hello$' \
    "sender delivers the message verbatim"

: > "$NC_CAPTURE"
# shellcheck disable=SC2086
PATH="$SBIN:$PATH" $TESTSH "$REPO/standalone/xymon-send.sh" \
    192.0.2.1:2984 "ping"
expect "$(cat "$NC_CAPTURE")" '^ARGS: 192\.0\.2\.1 2984$' \
    "host:port syntax overrides the port"

: > "$NC_CAPTURE"
# shellcheck disable=SC2086
printf 'line1\nline2\n' | PATH="$SBIN:$PATH" $TESTSH \
    "$REPO/standalone/xymon-send.sh" 192.0.2.1 -
expect "$(cat "$NC_CAPTURE")" '^line2$' "message on stdin works ('-')"

: > "$NC_CAPTURE"
# shellcheck disable=SC2086
PATH="$SBIN:$PATH" $TESTSH "$REPO/standalone/xymon-send.sh" \
    "192.0.2.1 192.0.2.2:3984" "multi"
expect "$(cat "$NC_CAPTURE")" '^ARGS: 192\.0\.2\.2 3984$' \
    "space-separated server list reaches every server"

# ----------------------------------------------------------------------
echo "--- standalone: xymon-run.sh + extensions ---"

# Simulated install tree, as the opkg package would lay it out.
STAGE="$TMP/xymon-standalone"
mkdir -p "$STAGE/ext" "$STAGE/etc"
cp "$REPO/standalone/xymon-run.sh" "$REPO/standalone/xymon-send.sh" "$STAGE/"
cp "$REPO/extensions/smart/smart.sh" "$STAGE/ext/smart.sh"
cp "$REPO/extensions/temp/temp.sh" "$STAGE/ext/temp.sh"
cp "$REPO/extensions/la/la.sh" "$STAGE/ext/la.sh"
cp "$REPO/extensions/memory/memory.sh" "$STAGE/ext/memory.sh"
cp "$TESTDIR/smart/smart_test.cfg" "$STAGE/etc/smart.cfg"
# The extensions must pick these up via $XYMONHOME/etc/<name>.cfg
cat > "$STAGE/etc/temp.cfg" <<EOF
TEMP_HWMON_DIR="$TEMPFIX/sys/class/hwmon"
TEMP_THERMAL_DIR="$EMPTYDIR"
EOF
cat > "$STAGE/etc/la.cfg" <<EOF
LA_LOADAVG="$LAFIX"
LA_NCPU=4
EOF
cat > "$STAGE/etc/memory.cfg" <<EOF
MEM_MEMINFO="$MEMFIX"
EOF
# XYMONTMP/XYMONCLIENTLOGS deliberately do not exist yet: the runner
# must create them (on OpenWrt /tmp is a RAM disk, configured
# subdirectories are gone after every reboot).
cat > "$STAGE/etc/standalone.cfg" <<EOF
XYMSRV="127.0.0.1"
MACHINEDOTS="turris.example.org"
XYMONTMP="$TMP/work/tmp"
XYMONCLIENTLOGS="$TMP/work/logs"
EOF

# The extension must find its config via \$XYMONHOME/etc, not SMART_CFG.
unset SMART_CFG 2>/dev/null || true
export STANDALONE_CFG="$STAGE/etc/standalone.cfg"
export NC_CAPTURE="$TMP/capture-run"
: > "$NC_CAPTURE"

# shellcheck disable=SC2086
PATH="$SBIN:$PATH" $TESTSH "$STAGE/xymon-run.sh" all
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "ok:   xymon-run.sh all exits 0"
else
    echo "FAIL: xymon-run.sh all exited with $rc"
    FAIL=1
fi

captured=$(cat "$NC_CAPTURE")
expect "$captured" '^ARGS: 127\.0\.0\.1 1984$' \
    "runner sends to the configured XYMSRV"
expect "$captured" '^status turris,example,org\.smart yellow ' \
    "status message with comma-encoded FQDN from MACHINEDOTS"
expect "$captured" '^data turris,example,org\.smart$' \
    "data message for the RRD graphs is sent too"
expect "$captured" '^tsda_pending : 8$' \
    "NCV payload arrives through the standalone transport"
expect "$captured" '^status turris,example,org\.temp yellow ' \
    "temp extension runs under the standalone runner"
expect "$captured" '^mv88e6xxx_internal : 85\.4$' \
    "temp NCV payload arrives, config read from \$XYMONHOME/etc"
expect "$captured" '^status turris,example,org\.la green ' \
    "la extension runs under the standalone runner"
expect "$captured" '^la5 : 1\.20$' \
    "la NCV payload arrives, config read from \$XYMONHOME/etc"
expect "$captured" '^status turris,example,org\.memory green ' \
    "memory extension runs under the standalone runner"
expect "$captured" '^used : 50\.0$' \
    "memory NCV payload arrives, config read from \$XYMONHOME/etc"
if [ -f "$TMP/work/logs/smart.log" ]; then
    echo "ok:   extension run log written to auto-created \$XYMONCLIENTLOGS"
else
    echo "FAIL: extension run log missing ($TMP/work/logs/smart.log)"
    FAIL=1
fi

# Dry run: nothing sent, report on stdout
: > "$NC_CAPTURE"
# shellcheck disable=SC2086
dryout=$(PATH="$SBIN:$PATH" $TESTSH "$STAGE/xymon-run.sh" -n smart)
expect "$dryout" '^status turris,example,org\.smart yellow ' \
    "dry run (-n) prints the report to stdout"
if [ -s "$NC_CAPTURE" ]; then
    echo "FAIL: dry run must not send anything"
    FAIL=1
else
    echo "ok:   dry run sends nothing"
fi

# Unknown extension -> error
# shellcheck disable=SC2086
if PATH="$SBIN:$PATH" $TESTSH "$STAGE/xymon-run.sh" nosuchext 2>/dev/null; then
    echo "FAIL: unknown extension should fail"
    FAIL=1
else
    echo "ok:   unknown extension reports an error"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
else
    echo "There were test failures."
fi
exit "$FAIL"
