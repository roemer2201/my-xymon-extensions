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
echo "--- fritzdsl ---"
export FAKECURL="$TESTDIR/fritzdsl/fakecurl"
export FRITZDSL_CFG="$TESTDIR/fritzdsl/fritzdsl_test.cfg"
unset FAKECURL_GETINFO FAKECURL_STATS FAKECURL_PPP FAKECURL_FAIL FAKECURL_401 2>/dev/null || true
rm -f "$TMP"/fritzdsl.*.state

# Healthy line
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/fritzdsl/fritzdsl.sh")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: fritzdsl.sh exited with $rc"
    printf '%s\n' "$out"
    exit 1
fi
expect "$out" '^status fritzbox\.fritzdsl green ' \
    "healthy line reports green to the configured REPORTHOST"
expect "$out" 'DSL line: Up at 116797/46719 kbit/s' \
    "summary line carries state and sync rate"
expect "$out" '&green DSL line status: Up \(path: Interleaved\)' \
    "line status detail with data path"
expect "$out" '^data fritzbox\.fritzdsl$'   "data message for the RRDs is sent"
expect "$out" '^rate_down : 116797$'        "downstream sync rate extracted"
expect "$out" '^rate_up : 46719$'           "upstream sync rate extracted"
expect "$out" '^maxrate_down : 130960$'     "attainable downstream rate extracted"
expect "$out" '^margin_down : 6\.5$' \
    "downstream noise margin converted from tenths of a dB"
expect "$out" '^margin_up : 8\.0$'          "upstream noise margin converted"
expect "$out" '^atten_down : 14\.2$'        "downstream attenuation converted"
expect "$out" '^crc : 56$'                  "CRC error counter extracted"
expect "$out" '^fec : 1234$'                "FEC error counter extracted"
expect "$out" '^hec : 12$'                  "HEC error counter extracted"
expect "$out" '^es : 42$'                   "errored seconds extracted"
expect "$out" '^ses : 1$'                   "severely errored seconds extracted"
expect "$out" '^retrain : 2$'               "link retrain counter extracted"
expect "$out" '^uptime : 372705$'           "PPP uptime extracted"
if [ -f "$TMP/fritzdsl.fritzbox.state" ]; then
    echo "ok:   state file written for the CRC rate check"
else
    echo "FAIL: state file missing ($TMP/fritzdsl.fritzbox.state)"
    FAIL=1
fi

# Rising CRC error rate + resync detection: fake a state file from
# 5 minutes ago with counter 0 and a larger uptime. 56 CRC errors in
# ~300 s = ~11.2/min, above the test threshold of 10/min; the uptime
# going backwards must yield the resync note.
printf '%s 0 999999\n' "$(($(date +%s) - 300))" > "$TMP/fritzdsl.fritzbox.state"
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/fritzdsl/fritzdsl.sh")
expect "$out" '^status fritzbox\.fritzdsl yellow ' \
    "rising CRC error rate turns the column yellow"
expect "$out" '&yellow CRC errors: 11\.[0-9]/min since the last poll' \
    "CRC rate note shows the per-minute rate"
expect "$out" 'connection was re-established since the last poll' \
    "uptime going backwards yields the resync note"

# Noise margin thresholds: downstream 4.5 dB (below warn 6),
# upstream 2.8 dB (below crit 3)
rm -f "$TMP"/fritzdsl.*.state
# shellcheck disable=SC2086
out=$(FAKECURL_GETINFO="$TESTDIR/fritzdsl/data/getinfo-lowmargin.xml" \
    $TESTSH "$REPO/extensions/fritzdsl/fritzdsl.sh")
expect "$out" '^status fritzbox\.fritzdsl red ' \
    "noise margin below the critical threshold turns the column red"
expect "$out" '&red upstream noise margin 2\.8 dB is below 3 dB' \
    "critical upstream margin flagged"
expect "$out" '&yellow downstream noise margin 4\.5 dB is below 6 dB' \
    "low downstream margin flagged"

# DSL line down
rm -f "$TMP"/fritzdsl.*.state
# shellcheck disable=SC2086
out=$(FAKECURL_GETINFO="$TESTDIR/fritzdsl/data/getinfo-down.xml" \
    $TESTSH "$REPO/extensions/fritzdsl/fritzdsl.sh")
expect "$out" '^status fritzbox\.fritzdsl red ' "line down reports red"
expect "$out" '&red DSL line status: Down'      "line down note present"
expect_not "$out" 'noise margin 0\.0 dB is below' \
    "margin thresholds are not applied while the line is down"

# No PPP/IP WAN service (HTTP 404 on GetStatusInfo): no uptime metric,
# but the column stays green
rm -f "$TMP"/fritzdsl.*.state
# shellcheck disable=SC2086
out=$(FAKECURL_PPP=404 $TESTSH "$REPO/extensions/fritzdsl/fritzdsl.sh")
expect "$out" '^status fritzbox\.fritzdsl green ' \
    "missing WAN status service does not degrade the column"
expect_not "$out" '^uptime :' "no uptime metric without a WAN status service"

# Box unreachable
# shellcheck disable=SC2086
out=$(FAKECURL_FAIL=1 $TESTSH "$REPO/extensions/fritzdsl/fritzdsl.sh")
expect "$out" '^status fritzbox\.fritzdsl red ' "unreachable box reports red"
expect "$out" 'cannot reach the FRITZ!Box'      "unreachable note present"

# Wrong credentials (HTTP 401)
# shellcheck disable=SC2086
out=$(FAKECURL_401=1 $TESTSH "$REPO/extensions/fritzdsl/fritzdsl.sh")
expect "$out" '^status fritzbox\.fritzdsl yellow ' \
    "authentication failure reports yellow"
expect "$out" 'TR-064 authentication failed' "authentication note present"

# curl not installed -> clear
# shellcheck disable=SC2086
out=$(FRITZDSL_CFG="$TESTDIR/fritzdsl/fritzdsl_test_nocurl.cfg" \
    $TESTSH "$REPO/extensions/fritzdsl/fritzdsl.sh")
expect "$out" '^status fritzbox\.fritzdsl clear ' "missing curl reports clear"
expect "$out" 'curl not found'                    "missing curl hint present"

# Not configured (no credentials): no report at all, hint on stderr
# shellcheck disable=SC2086
out=$(FRITZDSL_CFG="$TMP/does-not-exist.cfg" \
    $TESTSH "$REPO/extensions/fritzdsl/fritzdsl.sh" 2>"$TMP/fritzdsl.stderr")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: unconfigured fritzdsl.sh exited with $rc"
    FAIL=1
fi
if [ -n "$out" ]; then
    echo "FAIL: unconfigured fritzdsl.sh must not send/print a report"
    FAIL=1
else
    echo "ok:   unconfigured fritzdsl.sh stays silent (no ghost column)"
fi
expect "$(cat "$TMP/fritzdsl.stderr")" 'not configured' \
    "unconfigured fritzdsl.sh hints on stderr"

unset FRITZDSL_CFG

# ----------------------------------------------------------------------
echo "--- fritzwan ---"
export FAKECURL="$TESTDIR/fritzwan/fakecurl"
export FRITZWAN_CFG="$TESTDIR/fritzwan/fritzwan_test.cfg"
unset FAKECURL_CLP FAKECURL_ADDON FAKECURL_FAIL FAKECURL_401 2>/dev/null || true
rm -f "$TMP"/fritzwan.*.state

# First poll: no state yet, so link info only - rates need two polls
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/fritzwan/fritzwan.sh")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: fritzwan.sh exited with $rc"
    printf '%s\n' "$out"
    exit 1
fi
expect "$out" '^status fritzbox\.fritzwan green ' \
    "first poll reports green to the configured REPORTHOST"
expect "$out" '&green WAN link status: Up \(DSL\)' \
    "link status detail with access type"
expect "$out" 'rates appear with the next poll' \
    "first poll announces that rates follow"
expect "$out" '^maxbps_down : 100000000$' "downstream link capacity extracted"
expect "$out" '^maxbps_up : 40000000$'    "upstream link capacity extracted"
expect_not "$out" '^bps_down' "no throughput metric on the first poll"
if [ -f "$TMP/fritzwan.fritzbox.state" ]; then
    echo "ok:   state file written for the rate calculation"
else
    echo "FAIL: state file missing ($TMP/fritzwan.fritzbox.state)"
    FAIL=1
fi

# Second poll: state from ~5 minutes ago, 750 MB down / 75 MB up in
# 300 s = ~20/2 Mbit/s on a 100/40 Mbit link = ~20%/5% utilization
printf '%s 250000000000 111000000000 64\n' "$(($(date +%s) - 300))" \
    > "$TMP/fritzwan.fritzbox.state"
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/fritzwan/fritzwan.sh")
expect "$out" '^status fritzbox\.fritzwan green ' \
    "throughput below the (disabled) thresholds stays green"
expect "$out" 'WAN: Up, (19\.[0-9]|20\.0)/(1\.9|2\.0) Mbit/s' \
    "summary line carries the down/up throughput"
expect "$out" '^bps_down : (19[0-9]{6}|20000000)$' \
    "downstream throughput from the 64-bit counter delta"
expect "$out" '^bps_up : (19[0-9]{5}|2000000)$' \
    "upstream throughput from the 64-bit counter delta"
expect "$out" '^util_down : (19\.[0-9]|20\.0)$' \
    "downstream utilization derived from capacity"
expect "$out" '^util_up : (4\.9|5\.0)$' \
    "upstream utilization derived from capacity"
expect "$out" 'UPnP 64-bit counters' \
    "64-bit UPnP counters preferred as the source"

# Utilization thresholds: ~20% downstream trips UTIL_WARN=15
printf '%s 250000000000 111000000000 64\n' "$(($(date +%s) - 300))" \
    > "$TMP/fritzwan.fritzbox.state"
# shellcheck disable=SC2086
out=$(FRITZWAN_CFG="$TESTDIR/fritzwan/fritzwan_test_util.cfg" \
    $TESTSH "$REPO/extensions/fritzwan/fritzwan.sh")
expect "$out" '^status fritzbox\.fritzwan yellow ' \
    "utilization above UTIL_WARN turns the column yellow"
expect "$out" '&yellow downstream utilization (19\.[0-9]|20\.0)% is above 15%' \
    "utilization note names direction, value and threshold"

# Physical link down
rm -f "$TMP"/fritzwan.*.state
# shellcheck disable=SC2086
out=$(FAKECURL_CLP="$TESTDIR/fritzwan/data/clp-down.xml" \
    $TESTSH "$REPO/extensions/fritzwan/fritzwan.sh")
expect "$out" '^status fritzbox\.fritzwan red ' "link down reports red"
expect "$out" '&red WAN link status: Down'      "link down note present"

# UPnP counters unavailable: fall back to the TR-064 32-bit counters,
# including single-wrap correction (prev 4294000000 -> now 1000000)
printf '%s 4294000000 400000 32\n' "$(($(date +%s) - 300))" \
    > "$TMP/fritzwan.fritzbox.state"
# shellcheck disable=SC2086
out=$(FAKECURL_ADDON=404 $TESTSH "$REPO/extensions/fritzwan/fritzwan.sh")
expect "$out" 'TR-064 32-bit counters' \
    "falls back to TR-064 counters when UPnP is unavailable"
expect "$out" '^bps_down : [0-9]{5}$' \
    "32-bit counter wrap corrected (positive ~52 kbit/s rate)"
expect "$out" '^bps_up : 2[0-9]{3}$' "upstream rate from 32-bit counters"

# Login-free UPnP/IGD mode (MODE=igd, no credentials)
rm -f "$TMP"/fritzwan.*.state
# shellcheck disable=SC2086
out=$(FRITZWAN_CFG="$TESTDIR/fritzwan/fritzwan_test_igd.cfg" \
    $TESTSH "$REPO/extensions/fritzwan/fritzwan.sh")
expect "$out" '^status fritzbox\.fritzwan green ' \
    "MODE=igd works without credentials"
expect "$out" '&green WAN link status: Up' "IGD link status extracted"
expect "$out" 'UPnP 64-bit counters'       "IGD mode reads the 64-bit counters"

# MODE=igd with UPnP status info disabled on the box -> clear hint
# shellcheck disable=SC2086
out=$(FAKECURL_CLP=404 FAKECURL_ADDON=404 \
    FRITZWAN_CFG="$TESTDIR/fritzwan/fritzwan_test_igd.cfg" \
    $TESTSH "$REPO/extensions/fritzwan/fritzwan.sh")
expect "$out" '^status fritzbox\.fritzwan clear ' \
    "disabled UPnP status info reports clear in MODE=igd"
expect "$out" "Transmit status information over UPnP" \
    "clear status carries the UPnP activation hint"

# Box unreachable
# shellcheck disable=SC2086
out=$(FAKECURL_FAIL=1 $TESTSH "$REPO/extensions/fritzwan/fritzwan.sh")
expect "$out" '^status fritzbox\.fritzwan red ' "unreachable box reports red"
expect "$out" 'cannot reach the FRITZ!Box'      "unreachable note present"

# Wrong credentials (HTTP 401)
# shellcheck disable=SC2086
out=$(FAKECURL_401=1 $TESTSH "$REPO/extensions/fritzwan/fritzwan.sh")
expect "$out" '^status fritzbox\.fritzwan yellow ' \
    "authentication failure reports yellow"
expect "$out" 'TR-064 authentication failed' "authentication note present"

# Not configured (no credentials, MODE=auto): no report, hint on stderr
# shellcheck disable=SC2086
out=$(FRITZWAN_CFG="$TMP/does-not-exist.cfg" \
    $TESTSH "$REPO/extensions/fritzwan/fritzwan.sh" 2>"$TMP/fritzwan.stderr")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: unconfigured fritzwan.sh exited with $rc"
    FAIL=1
fi
if [ -n "$out" ]; then
    echo "FAIL: unconfigured fritzwan.sh must not send/print a report"
    FAIL=1
else
    echo "ok:   unconfigured fritzwan.sh stays silent (no ghost column)"
fi
expect "$(cat "$TMP/fritzwan.stderr")" 'not configured' \
    "unconfigured fritzwan.sh hints on stderr"

unset FRITZWAN_CFG

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

# TESTS directive: "all" runs exactly the configured selection
cat >> "$STAGE/etc/standalone.cfg" <<EOF
TESTS="temp la"
EOF
: > "$NC_CAPTURE"
# shellcheck disable=SC2086
PATH="$SBIN:$PATH" $TESTSH "$STAGE/xymon-run.sh" all
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "ok:   xymon-run.sh all with TESTS exits 0"
else
    echo "FAIL: xymon-run.sh all with TESTS exited with $rc"
    FAIL=1
fi
captured=$(cat "$NC_CAPTURE")
expect "$captured" '^status turris,example,org\.temp ' \
    "TESTS: listed extension temp runs"
expect "$captured" '^status turris,example,org\.la ' \
    "TESTS: listed extension la runs"
expect_not "$captured" '^status turris,example,org\.(smart|memory) ' \
    "TESTS: unlisted extensions do not run"

# Extensions named explicitly run even when not in TESTS
: > "$NC_CAPTURE"
# shellcheck disable=SC2086
PATH="$SBIN:$PATH" $TESTSH "$STAGE/xymon-run.sh" memory
expect "$(cat "$NC_CAPTURE")" '^status turris,example,org\.memory ' \
    "explicit extension runs regardless of TESTS"

# A TESTS entry without an installed script -> error
cat >> "$STAGE/etc/standalone.cfg" <<EOF
TESTS="temp nosuchext"
EOF
# shellcheck disable=SC2086
if PATH="$SBIN:$PATH" $TESTSH "$STAGE/xymon-run.sh" all 2>/dev/null; then
    echo "FAIL: unknown extension in TESTS should fail"
    FAIL=1
else
    echo "ok:   unknown extension in TESTS reports an error"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
else
    echo "There were test failures."
fi
exit "$FAIL"
