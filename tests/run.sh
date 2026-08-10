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

expect_rate() {
    # expect_rate <output> <metric-name> <expected> <label>
    # Asserts that an NCV line "<metric-name> : <value>" exists and that
    # <value> is within 3 % of <expected>.
    #
    # Use this instead of expect() for every metric an extension derives
    # by dividing through the elapsed time. Those divide by the gap
    # between the timestamp a test writes into the state file and the
    # script's own date(1) call - two separate date(1) calls in two
    # processes, so under load they land one or more seconds apart. With
    # a 300 s fixture one single second already moves 800.0 kbit/s to
    # 797.3 and 10.0 % airtime to 9.9, which made exact assertions flake
    # on loaded CI runners. 3 % absorbs a skew of up to ~9 s and still
    # catches a wrong scale factor or a miscomputed delta, which are off
    # by much more. Counter differences that are not divided by time
    # (if_link) stay on plain expect().
    er_line=$(printf '%s\n' "$1" | grep -E "^$2 : " | head -1)
    if [ -z "$er_line" ]; then
        echo "FAIL: $4 (no \"$2\" line at all)"
        FAIL=1
        return
    fi
    er_val=${er_line#* : }
    if awk -v v="$er_val" -v e="$3" 'BEGIN {
            if (e == 0 || v !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
            d = (v > e) ? v - e : e - v
            exit !(d / e <= 0.03)
        }'; then
        echo "ok:   $4"
    else
        echo "FAIL: $4 ($2 is $er_val, expected about $3)"
        FAIL=1
    fi
}

ncv_view() {
    # ncv_view <status-message> -> the part of the message that the
    # Xymon server's NCV parser (xymond_rrd) actually looks at: the
    # first line carries the date and is skipped, and everything
    # between <!-- ncv_skipstart --> and <!-- ncv_skipend --> is
    # dropped. Anything left that looks like "NAME : VALUE" or
    # "NAME = VALUE" ends up in an RRD.
    printf '%s\n' "$1" | awk '
        NR == 1                  { next }
        /<!-- ncv_skipstart -->/ { skip = 1; next }
        /<!-- ncv_skipend -->/   { skip = 0; next }
        !skip'
}

# ----------------------------------------------------------------------
echo "--- smart ---"
export FAKESMARTCTL="$TESTDIR/smart/fakesmartctl"
export FAKEMMC="$TESTDIR/smart/fakemmc"
export SMART_CFG="$TESTDIR/smart/smart_test.cfg"
export XYMONTMP="$TMP"
export MACHINE="testhost"
unset XYMON XYMSRV XYMONHOME 2>/dev/null || true
rm -f "$TMP"/smart.*.state

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

# DWPD - lifetime average: written / capacity / (hours/24), computed
# from drive-firmware counters only, so no state file is involved.
# tssd: 23288 GiB / 931.5 GiB / 730 d, tsdk: 21543 / 447.1 / 1987.8,
# tsdc: 2549 / 476.9 / 73.1, tnvme0: 15784 / 931.5 / 365.
expect "$out" '^tssd_dwpd : 0\.03425$' \
    "lifetime dwpd (ATA, 512-byte LBA writes, User Capacity)"
expect "$out" '^tsdk_dwpd : 0\.02424$' \
    "lifetime dwpd (ATA, GiB-native writes)"
expect "$out" '^tsdc_dwpd : 0\.07314$' \
    "lifetime dwpd (32-MiB write units, drive not in smartctl database)"
expect "$out" '^tnvme0_dwpd : 0\.04642$' \
    "lifetime dwpd (NVMe Data Units Written, namespace capacity)"
expect_not "$out" '^tsda_dwpd' \
    "no dwpd for a disk without a host-writes attribute (HDD)"
expect "$out" 'dwpd=0\.03425' "dwpd also shown in the status section"

# dwpdrecent needs a previous sample - the first run only seeds one.
expect_not "$out" '_dwpdrecent' \
    "no dwpdrecent on the first run (state file was just created)"
expect "$(cat "$TMP/smart.testhost.state" 2>/dev/null)" \
    '^S tssd S3Z8TEST [0-9]+ 23288\.4[0-9]+$' \
    "sample keeps the drive's sub-GiB write resolution (512-byte LBAs)"
expect "$(cat "$TMP/smart.testhost.state" 2>/dev/null)" \
    '^S tsdc 50026B7TEST2 [0-9]+ 2549\.125' \
    "sample keeps sub-GiB resolution for 32-MiB write units too"
expect "$(cat "$TMP/smart.testhost.state" 2>/dev/null)" \
    '^S tsdk 50026B7TEST [0-9]+ 21543$' \
    "GiB-native counter stays whole GiB - that is the drive's own limit"
expect_not "$(cat "$TMP/smart.testhost.state" 2>/dev/null)" '^S tsda ' \
    "no sample seeded for a disk without writes/capacity data"

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

# --- dwpdrecent: rolling window over a persisted sample ---------------
# A usable reference sample is between one and two windows old (default
# 24h/48h). 30h back with 22788 GiB written means 500 GiB over 1.25
# days on a 931.5 GiB disk -> 0.429 writes per day.
smart_state="$TMP/smart.testhost.state"
now=$(date +%s)
# dwpdrecent divides by the time actually elapsed, which includes the
# script's own runtime, so the trailing decimals of these values drift
# by a digit or two between runs. The assertions pin three decimals -
# enough to prove the arithmetic, loose enough not to flap on a busy
# machine.

rm -f "$TMP"/smart.*.state
printf 'S tssd S3Z8TEST %s 22788\n' "$((now - 108000))" > "$smart_state"
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/smart/smart.sh")
expect "$out" '^tssd_dwpdrecent : 0\.429[0-9][0-9]$' \
    "dwpdrecent over the rolling window (500 GiB in 30h)"
expect "$(cat "$smart_state")" '^S tssd S3Z8TEST [0-9]+ 23288\.4[0-9]+$' \
    "a new sample is appended after the sample interval"
expect "$(cat "$smart_state")" '^S tssd S3Z8TEST [0-9]+ 22788$' \
    "the reference sample is kept until it ages out of the window"

# Warm-up: no sample old enough for the full 24h window yet, but the
# oldest one is past DWPD_WARMUP_HOURS, so the average is taken over
# that shorter span instead of leaving the graph empty for a whole day.
# 100.413 GiB over 7h on a 931.5 GiB disk -> 0.36959 writes per day.
rm -f "$TMP"/smart.*.state
printf 'S tssd S3Z8TEST %s 23188\n' "$((now - 25200))" > "$smart_state"
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/smart/smart.sh")
expect "$out" '^tssd_dwpdrecent : 0\.369[0-9][0-9]$' \
    "dwpdrecent reported during warm-up over the oldest sample"

# Below the warm-up threshold nothing is reported yet.
rm -f "$TMP"/smart.*.state
printf 'S tssd S3Z8TEST %s 23188\n' "$((now - 10800))" > "$smart_state"
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/smart/smart.sh")
expect_not "$out" '^tssd_dwpdrecent' \
    "no dwpdrecent before DWPD_WARMUP_HOURS has elapsed"

# A full-window reference wins over the warm-up fallback: with samples
# at 30h and 7h the 30h one must be used (0.08624, not 0.36959).
rm -f "$TMP"/smart.*.state
{
    printf 'S tssd S3Z8TEST %s 23188\n' "$((now - 108000))"
    printf 'S tssd S3Z8TEST %s 23188\n' "$((now - 25200))"
} > "$smart_state"
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/smart/smart.sh")
expect "$out" '^tssd_dwpdrecent : 0\.086[0-9][0-9]$' \
    "full window takes precedence over the warm-up fallback"

# Reference younger than the window: no value yet, sample untouched.
rm -f "$TMP"/smart.*.state
printf 'S tssd S3Z8TEST %s 23000\n' "$((now - 60))" > "$smart_state"
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/smart/smart.sh")
expect_not "$out" '^tssd_dwpdrecent' \
    "no dwpdrecent before the window has elapsed"
expect "$(cat "$smart_state")" "^S tssd S3Z8TEST $((now - 60)) 23000\$" \
    "sample kept unchanged while the window is still filling"

# Losing or corrupting the state must never yield a wrong value: each
# of these silently re-seeds and simply reports nothing this round.
for c in "corrupt:S tssd" \
         "swapped:S tssd OLDSERIAL $((now - 108000)) 100" \
         "reset:S tssd S3Z8TEST $((now - 108000)) 99999" \
         "stale:S tssd S3Z8TEST $((now - 999999)) 100"; do
    rm -f "$TMP"/smart.*.state
    printf '%s\n' "${c#*:}" > "$smart_state"
    # shellcheck disable=SC2086
    out=$($TESTSH "$REPO/extensions/smart/smart.sh")
    rc=$?
    [ "$rc" -eq 0 ] || { echo "FAIL: smart.sh exited $rc on ${c%%:*} state"; FAIL=1; }
    expect_not "$out" '^tssd_dwpdrecent' \
        "no dwpdrecent value from ${c%%:*} state"
    expect "$(cat "$smart_state")" '^S tssd S3Z8TEST [0-9]+ 23288\.4[0-9]+$' \
        "${c%%:*} state is silently re-seeded"
done

# A device missing for one run keeps its history (transient smartctl
# failure, disk in standby); samples older than two windows are pruned.
rm -f "$TMP"/smart.*.state
{
    printf 'S tabsent ABSENTSERIAL %s 500\n' "$((now - 3600))"
    printf 'S tabsent ABSENTSERIAL %s 100\n' "$((now - 999999))"
} > "$smart_state"
# shellcheck disable=SC2086
$TESTSH "$REPO/extensions/smart/smart.sh" > /dev/null
expect "$(cat "$smart_state")" "^S tabsent ABSENTSERIAL $((now - 3600)) 500\$" \
    "samples of a device not seen this run are carried forward"
expect_not "$(cat "$smart_state")" '^S tabsent ABSENTSERIAL [0-9]+ 100$' \
    "samples older than two windows are pruned"

# DWPD_MIN_HOURS guard: raised above every fixture's power-on hours.
rm -f "$TMP"/smart.*.state
# shellcheck disable=SC2086
out=$(SMART_CFG="$TESTDIR/smart/smart_test_dwpd.cfg" \
    $TESTSH "$REPO/extensions/smart/smart.sh")
expect_not "$out" '_dwpd :' \
    "no lifetime dwpd below DWPD_MIN_HOURS power-on hours"
rm -f "$TMP"/smart.*.state

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

# The NCV parser treats "=" like ":", so the human-readable sensor
# lines must be fenced off - otherwise every one of them would become
# an RRD dataset of its own.
view=$(ncv_view "$out")
expect "$view" '^armada_thermal_temp1 : 78\.1$' \
    "NCV block stays visible to the server's parser"
expect_not "$view" '=' \
    "no '=' line reaches the NCV parser (display lines are fenced off)"

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

# Stuck/invalid sensor (e.g. mt7915/mt76 wifi radio hwmon on
# OpenWrt/TurrisOS): a fixed bogus reading of several hundred degrees
# must not turn the column red - it is ignored instead.
# shellcheck disable=SC2086
out=$(TEMP_HWMON_DIR="$TESTDIR/temp/mt7915boot/sys/class/hwmon" \
    TEMP_THERMAL_DIR="$EMPTYDIR" $TESTSH "$REPO/extensions/temp/temp.sh")
expect "$out" '^status testhost\.temp green ' \
    "implausible reading does not turn the column red"
expect "$out" '&clear mt7915_wifi0 = 491\.0 C \(ignored: outside plausible range -40\.\.150 C' \
    "implausible sensor reported as clear with an explanatory note"
expect "$out" '&green cwl_thermal_temp1 = 62\.2 C' \
    "a normal sensor alongside the glitching one is still scored"
expect_not "$out" '^mt7915_wifi0 : ' \
    "implausible reading is excluded from the NCV data"
expect "$out" '^cwl_thermal_temp1 : 62\.2$' \
    "the normal sensor still gets an NCV line"
view=$(ncv_view "$out")
expect_not "$view" '491' \
    "implausible value is invisible to the NCV parser (never hits the RRD)"
expect_not "$view" 'mt7915' \
    "no dataset is created for the stuck sensor at all"
expect "$view" '^cwl_thermal_temp1 : 62\.2$' \
    "the plausible sensor is still graphed"

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
expect "$out" '^status testhost\.mem green ' \
    "memory status green (50% used below default 80), default column \"mem\""
expect "$out" '&green memory used 50\.0% \(1000 MB of 2000 MB, 1000 MB available\)' \
    "used percent and MB summary computed from MemTotal/MemAvailable"
expect "$out" '^used : 50\.0$' "memory NCV line"
expect_not "$out" 'estimated as MemFree' \
    "no estimation note when the kernel provides MemAvailable"

# shellcheck disable=SC2086
out=$(MEM_MEMINFO="$MEMFIX" MEM_WARN=50 \
    $TESTSH "$REPO/extensions/memory/memory.sh")
expect "$out" '^status testhost\.mem yellow ' \
    "MEM_WARN from the environment turns the column yellow (50.0 >= 50)"

# shellcheck disable=SC2086
out=$(MEM_MEMINFO="$MEMFIX" MEM_CRIT=45 \
    $TESTSH "$REPO/extensions/memory/memory.sh")
expect "$out" '^status testhost\.mem red ' \
    "MEM_CRIT from the environment turns the column red"

# shellcheck disable=SC2086
out=$(MEM_MEMINFO="$TESTDIR/memory/meminfo-noavail" \
    $TESTSH "$REPO/extensions/memory/memory.sh")
expect "$out" '^status testhost\.mem green ' \
    "kernel without MemAvailable still reports"
expect "$out" '^used : 65\.6$' \
    "fallback estimate MemFree+Buffers+Cached used"
expect "$out" 'estimated as MemFree \+ Buffers \+ Cached' \
    "estimation note shown when MemAvailable is missing"

# shellcheck disable=SC2086
out=$(MEM_MEMINFO="$TMP/no-such-meminfo" \
    $TESTSH "$REPO/extensions/memory/memory.sh")
expect "$out" '^status testhost\.mem clear ' \
    "missing /proc/meminfo reports clear, not red"

# shellcheck disable=SC2086
out=$(MEM_MEMINFO="$MEMFIX" MEM_COLUMN=memory \
    $TESTSH "$REPO/extensions/memory/memory.sh")
expect "$out" '^status testhost\.memory green ' \
    "column name is overridable via MEM_COLUMN (e.g. back to the stock name)"

# ----------------------------------------------------------------------
echo "--- disk ---"
FAKEDF="$TESTDIR/disk/fakedf"

# Turris data (GNU df): /dev hidden by default, everything below the
# default thresholds -> green
# shellcheck disable=SC2086
out=$(DISK_DF="$FAKEDF" FAKEDF_OUTPUT="$TESTDIR/disk/data/df-turris.txt" \
    $TESTSH "$REPO/extensions/disk/disk.sh")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: disk.sh exited with $rc"
    printf '%s\n' "$out"
    exit 1
fi
expect "$out" '^status testhost\.disk green ' \
    "disk status green (all filesystems below the default 90/95)"
expect "$out" '&green / 40% used \(2\.8G of 7\.3G, 4\.3G free\)' \
    "root filesystem line with human-readable sizes"
expect "$out" '&green /srv 81% used \(356\.3G of 447\.1G, 88\.6G free\)' \
    "81% used stays green below the default thresholds"
expect "$out" '&green /tmp 11% used' \
    "tmpfs mounts other than /dev are reported"
expect "$out" '^/dev/sda +468851544 +373607712 +92898704 +81% /srv$' \
    "df-style table line for the server's disk RRD parser"
expect "$out" '^Device +1024-blocks +Used +Available +Use% Mounted on$' \
    "df-style table header present (\"Device\", never \"Filesystem\")"
expect_not "$out" '% /dev$' \
    "default DISK_EXCLUDE hides /dev from the table"
expect_not "$out" '&(green|yellow|red) /dev ' \
    "default DISK_EXCLUDE hides /dev from the details"
expect "$out" '^&clear 1 filesystem\(s\) hidden \(DISK_EXCLUDE=/dev,/rom\)$' \
    "exclusion note counts the hidden filesystems"
expect_not "$out" ': [0-9.]+ *$' \
    "no \"text : number\" lines that would trigger the server's NCV parser"

# Emulate the server's disk RRD handler (xymond_rrd, do_disk.c) for
# the Unix format: it skips the first line, every line without a "/",
# every line starting with "&" and every line containing " red " or
# " yellow " - and turns EVERY other line into a filesystem RRD named
# after its 6th field ("/" -> ",", a bare "/" -> ",root"). A line with
# fewer than six fields yields an empty name, i.e. a bogus "disk.rrd".
do_disk_rrds() { # do_disk_rrds <output>
    printf '%s\n' "$1" | awk '
        NR == 1                                     { next }
        index($0, "/") == 0                         { next }
        substr($0, 1, 1) == "&"                     { next }
        index($0, " red ") || index($0, " yellow ") { next }
        {
            name = (NF >= 6) ? $6 : ""
            gsub(/\//, ",", name)
            if (name == ",") name = ",root"
            print "disk" name ".rrd"
        }'
}

check_disk_rrds() { # check_disk_rrds <output> <expected list> <description>
    c_got=$(do_disk_rrds "$1" | tr '\n' ' ' | sed 's/  *$//')
    if [ "$c_got" = "$2" ]; then
        echo "ok:   $3"
    else
        echo "FAIL: $3"
        echo "      expected RRDs: $2"
        echo "      got RRDs:      $c_got"
        FAIL=1
    fi
}

# The handler guesses the message format from magic words anywhere in
# the message. "Filesystem" selects the Windows format, which names
# the RRD after the device column instead of the mount point (that is
# how "disk,tmpfs.rrd" gets created); the others pick even more exotic
# formats. None of them may appear in our message.
check_disk_format() { # check_disk_format <output> <description>
    c_bad=""
    for c_w in Filesystem DASD NetAPP "NetWare Volumes" Summary \
               " xfs " " efs " " cxfs " netapp.pl dbcheck.pl; do
        case "$1" in
            *"$c_w"*) c_bad="${c_bad}${c_bad:+, }'${c_w}'" ;;
        esac
    done
    if [ -n "$c_bad" ]; then
        echo "FAIL: $2 (message triggers a non-Unix format guess: $c_bad)"
        FAIL=1
    else
        echo "ok:   $2"
    fi
}

check_disk_format "$out" "no magic word switches the parser off the Unix format"
check_disk_rrds "$out" "disk,root.rrd disk,tmp.rrd disk,srv.rrd" \
    "the parser sees exactly the reported mount points, no bogus RRD"

# BusyBox df from a Zyxel NWA50AX Pro: /rom is 100% full by design
# and must be hidden by default, the overlay is reported
# shellcheck disable=SC2086
out=$(DISK_DF="$FAKEDF" FAKEDF_OUTPUT="$TESTDIR/disk/data/df-nwa.txt" \
    $TESTSH "$REPO/extensions/disk/disk.sh")
expect "$out" '^status testhost\.disk green ' \
    "BusyBox df output parses, 100% /rom does not turn anything red"
expect_not "$out" '&(green|yellow|red) /rom ' \
    "default DISK_EXCLUDE hides the always-full /rom from the details"
expect_not "$out" '% /rom$' \
    "default DISK_EXCLUDE hides /rom from the table"
expect "$out" '&green /overlay 54% used \(15\.8M of 31\.0M, 13\.6M free\)' \
    "overlay partition reported with M-range sizes"
expect "$out" '&green / 54% used' \
    "overlayfs root mount reported separately"
# The regression this guards: with "tmpfs" (no slash) as the first
# device column the server used to name the first RRD after the
# device - "disk,tmpfs.rrd" instead of "disk,tmp.rrd" - and the
# footer note produced an extra, nameless "disk.rrd".
check_disk_format "$out" "BusyBox df output keeps the parser on the Unix format"
check_disk_rrds "$out" "disk,tmp.rrd disk,overlay.rrd disk,root.rrd" \
    "a slash-less first device column still yields mount-point RRDs"

# Global thresholds from the environment
# shellcheck disable=SC2086
out=$(DISK_DF="$FAKEDF" FAKEDF_OUTPUT="$TESTDIR/disk/data/df-nwa.txt" \
    DISK_WARN=50 $TESTSH "$REPO/extensions/disk/disk.sh")
expect "$out" '^status testhost\.disk yellow ' \
    "DISK_WARN from the environment turns the column yellow"
expect "$out" '&yellow /overlay 54% used .*reached the yellow threshold \(50%\)' \
    "yellow filesystem line names the threshold"
expect "$out" '&green /tmp 1% used' \
    "filesystems below the threshold stay green in a yellow report"

# shellcheck disable=SC2086
out=$(DISK_DF="$FAKEDF" FAKEDF_OUTPUT="$TESTDIR/disk/data/df-nwa.txt" \
    DISK_CRIT=54 $TESTSH "$REPO/extensions/disk/disk.sh")
expect "$out" '^status testhost\.disk red ' \
    "DISK_CRIT from the environment turns the column red"
expect "$out" '&red /overlay 54% used .*reached the red threshold \(54%\)' \
    "red filesystem line names the threshold"

# Per-mount thresholds: /srv gets 80/90, the rest keeps the defaults
# shellcheck disable=SC2086
out=$(DISK_DF="$FAKEDF" FAKEDF_OUTPUT="$TESTDIR/disk/data/df-turris.txt" \
    DISK_THRESHOLDS="/srv:80:90" $TESTSH "$REPO/extensions/disk/disk.sh")
expect "$out" '^status testhost\.disk yellow ' \
    "DISK_THRESHOLDS pattern turns /srv yellow"
expect "$out" '&yellow /srv 81% used .*reached the yellow threshold \(80%\)' \
    "per-mount threshold applied to the matching mount"
expect "$out" '&green / 40% used' \
    "non-matching mounts keep the global thresholds"
expect "$out" '^&clear Per-mount thresholds apply \(DISK_THRESHOLDS=/srv:80:90\)$' \
    "per-mount thresholds noted in the footer"
check_disk_rrds "$out" "disk,root.rrd disk,tmp.rrd disk,srv.rrd" \
    "the DISK_THRESHOLDS note feeds no bogus RRD to the disk parser"

# Many patterns: the comma-joined footer lists must stay single
# fields, or the disk parser would read a pattern as a mount point
# shellcheck disable=SC2086
out=$(DISK_DF="$FAKEDF" FAKEDF_OUTPUT="$TESTDIR/disk/data/df-turris.txt" \
    DISK_THRESHOLDS="/a:1:2 /b:3:4 /srv:80:90" \
    DISK_EXCLUDE="/dev /rom /nosuch /other*" \
    $TESTSH "$REPO/extensions/disk/disk.sh")
expect "$out" '^status testhost\.disk yellow ' \
    "long pattern lists still evaluate correctly"
check_disk_rrds "$out" "disk,root.rrd disk,tmp.rrd disk,srv.rrd" \
    "long pattern lists feed no bogus RRD to the disk parser"

# DISK_EXCLUDE patterns also match the device column
# shellcheck disable=SC2086
out=$(DISK_DF="$FAKEDF" FAKEDF_OUTPUT="$TESTDIR/disk/data/df-turris.txt" \
    DISK_EXCLUDE="tmpfs /rom" $TESTSH "$REPO/extensions/disk/disk.sh")
expect_not "$out" '/tmp' \
    "DISK_EXCLUDE matches the device column (tmpfs hides /tmp)"
expect "$out" '^&clear 2 filesystem\(s\) hidden \(DISK_EXCLUDE=tmpfs,/rom\)$' \
    "both tmpfs mounts counted as hidden"
expect "$out" '&green /srv 81% used' \
    "real filesystems survive a device-column exclude"

# Column name override
# shellcheck disable=SC2086
out=$(DISK_DF="$FAKEDF" FAKEDF_OUTPUT="$TESTDIR/disk/data/df-nwa.txt" \
    DISK_COLUMN=df $TESTSH "$REPO/extensions/disk/disk.sh")
expect "$out" '^status testhost\.df green ' \
    "column name is overridable via DISK_COLUMN"

# df produces nothing usable -> clear
# shellcheck disable=SC2086
out=$(DISK_DF="$FAKEDF" FAKEDF_OUTPUT=/dev/null FAKEDF_RC=1 \
    $TESTSH "$REPO/extensions/disk/disk.sh")
expect "$out" '^status testhost\.disk clear ' \
    "unusable df output reports clear, not red"
expect "$out" 'no usable filesystem lines' "unusable-output note present"
check_disk_rrds "$out" "" \
    "the unusable-output note feeds no RRD to the disk parser"

# No df at all -> clear
# shellcheck disable=SC2086
out=$(DISK_DF="$TMP/no-such-df" $TESTSH "$REPO/extensions/disk/disk.sh")
expect "$out" '^status testhost\.disk clear ' \
    "missing df reports clear, not red"
expect "$out" 'df not found' "missing df hint present"
check_disk_rrds "$out" "" \
    "an absolute DISK_DF path in the note feeds no RRD to the disk parser"

# ----------------------------------------------------------------------
echo "--- opkg ---"
export FAKEOPKG="$TESTDIR/opkg/fakeopkg"
export FAKEOPKG_LISTSDIR="$TMP/opkg-lists"
export FAKEOPKG_LOG="$TMP/opkg-calls"
export OPKG_CFG="$TESTDIR/opkg/opkg_test.cfg"
unset FAKEOPKG_UPDATE_RC FAKEOPKG_LIST_RC FAKEOPKG_UPGRADABLE 2>/dev/null || true

# Missing lists + OPKG_UPDATE=auto (default): the extension must run
# "opkg update" itself (the fake creates the lists), then report green
rm -rf "$FAKEOPKG_LISTSDIR"
: > "$FAKEOPKG_LOG"
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/opkg/opkg.sh")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: opkg.sh exited with $rc"
    printf '%s\n' "$out"
    exit 1
fi
expect "$out" '^status testhost\.opkg green ' \
    "no upgradable packages reports green"
expect "$(cat "$FAKEOPKG_LOG")" '^update$' \
    "missing package lists trigger opkg update"
expect "$out" 'refreshed by this run' \
    "status notes that this run refreshed the lists"
expect "$out" '&green all packages are up to date' \
    "up-to-date detail line present"
expect "$out" '^updates : 0$'  "opkg NCV line updates"
expect "$out" '^critical : 0$' "opkg NCV line critical"

# Fresh lists (just created by the fake): no update call
: > "$FAKEOPKG_LOG"
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/opkg/opkg.sh")
expect_not "$(cat "$FAKEOPKG_LOG")" '^update$' \
    "fresh lists do not trigger opkg update"
expect "$out" '^status testhost\.opkg green ' \
    "fresh lists still report green"

# Stale lists (mtime far in the past): update runs again
touch -t 202001010000 "$FAKEOPKG_LISTSDIR/base"
: > "$FAKEOPKG_LOG"
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/opkg/opkg.sh")
expect "$(cat "$FAKEOPKG_LOG")" '^update$' \
    "stale lists trigger opkg update"
expect "$out" '^status testhost\.opkg green ' \
    "refreshed stale lists report green"

# Upgradable packages, none critical -> yellow
# shellcheck disable=SC2086
out=$(FAKEOPKG_UPGRADABLE="$TESTDIR/opkg/data/upgradable-plain.txt" \
    $TESTSH "$REPO/extensions/opkg/opkg.sh")
expect "$out" '^status testhost\.opkg yellow ' \
    "upgradable packages report yellow"
expect "$out" '&yellow luci-base git-24\.086\.45142-09d5a38 -> git-24\.114\.85298-1c4b2a9' \
    "per-package line carries old and new version"
expect "$out" '2 package\(s\) can be upgraded, 0 security-relevant' \
    "summary counts the upgradable packages"
expect "$out" '^updates : 2$'  "updates NCV counts the packages"
expect "$out" '^critical : 0$' "critical NCV stays 0 without a match"

# Upgradable packages matching OPKG_CRITICAL -> red
# shellcheck disable=SC2086
out=$(FAKEOPKG_UPGRADABLE="$TESTDIR/opkg/data/upgradable-critical.txt" \
    $TESTSH "$REPO/extensions/opkg/opkg.sh")
expect "$out" '^status testhost\.opkg red ' \
    "security-relevant upgradable package reports red"
expect "$out" '&red dropbear 2022\.82-2 -> 2022\.82-6 \(matches critical pattern "dropbear\*"\)' \
    "critical package line names the matching pattern"
expect "$out" '&red libopenssl3 .*matches critical pattern' \
    "wildcard pattern \\*openssl\\* matches libopenssl3"
expect "$out" '&yellow luci-base ' \
    "non-critical packages stay yellow in a red report"
expect "$out" '^updates : 4$'  "updates NCV counts all packages"
expect "$out" '^critical : 2$' "critical NCV counts the matches"

# OPKG_CRITICAL is overridable through the environment
# shellcheck disable=SC2086
out=$(FAKEOPKG_UPGRADABLE="$TESTDIR/opkg/data/upgradable-plain.txt" \
    OPKG_CRITICAL="luci-*" $TESTSH "$REPO/extensions/opkg/opkg.sh")
expect "$out" '^status testhost\.opkg red ' \
    "OPKG_CRITICAL from the environment turns the column red"

# "opkg update" fails but old (stale) lists exist: warn, but still
# evaluate the old lists
touch -t 202001010000 "$FAKEOPKG_LISTSDIR/base"
# shellcheck disable=SC2086
out=$(FAKEOPKG_UPDATE_RC=1 \
    FAKEOPKG_UPGRADABLE="$TESTDIR/opkg/data/upgradable-plain.txt" \
    $TESTSH "$REPO/extensions/opkg/opkg.sh")
expect "$out" '^status testhost\.opkg yellow ' \
    "failed opkg update reports yellow"
expect "$out" '&yellow opkg update failed' \
    "failed update note present"
expect "$out" '&yellow luci-base ' \
    "old lists are still evaluated after a failed update"

# "opkg update" fails and there are no lists at all: status unknown
rm -rf "$FAKEOPKG_LISTSDIR"
# shellcheck disable=SC2086
out=$(FAKEOPKG_UPDATE_RC=1 $TESTSH "$REPO/extensions/opkg/opkg.sh")
expect "$out" '^status testhost\.opkg yellow ' \
    "no lists and failed update reports yellow"
expect "$out" 'update status unknown' \
    "unknown-status note present"
expect_not "$out" '^updates :' \
    "no NCV lines when the update status is unknown"

# OPKG_UPDATE=never + missing lists: yellow, and no update call
rm -rf "$FAKEOPKG_LISTSDIR"
: > "$FAKEOPKG_LOG"
# shellcheck disable=SC2086
out=$(OPKG_UPDATE=never $TESTSH "$REPO/extensions/opkg/opkg.sh")
expect "$out" '^status testhost\.opkg yellow ' \
    "OPKG_UPDATE=never with missing lists reports yellow"
expect "$out" 'update status unknown' \
    "missing lists yield the unknown-status note"
expect_not "$(cat "$FAKEOPKG_LOG")" '^update$' \
    "OPKG_UPDATE=never never calls opkg update"

# OPKG_UPDATE=never + stale lists: warn about the age, evaluate anyway
mkdir -p "$FAKEOPKG_LISTSDIR"
touch -t 202001010000 "$FAKEOPKG_LISTSDIR/base"
# shellcheck disable=SC2086
out=$(OPKG_UPDATE=never \
    FAKEOPKG_UPGRADABLE="$TESTDIR/opkg/data/upgradable-plain.txt" \
    $TESTSH "$REPO/extensions/opkg/opkg.sh")
expect "$out" '^status testhost\.opkg yellow ' \
    "OPKG_UPDATE=never with stale lists reports yellow"
expect "$out" '&yellow package lists are older than 24 hour\(s\)' \
    "staleness note present with OPKG_UPDATE=never"
expect "$out" '&yellow luci-base ' \
    "stale lists are still evaluated with OPKG_UPDATE=never"

# OPKG_MAXAGE=0 disables the age check: stale lists count as fresh
: > "$FAKEOPKG_LOG"
# shellcheck disable=SC2086
out=$(OPKG_MAXAGE=0 $TESTSH "$REPO/extensions/opkg/opkg.sh")
expect "$out" '^status testhost\.opkg green ' \
    "OPKG_MAXAGE=0 reports green from old lists"
expect "$out" 'age check disabled' \
    "OPKG_MAXAGE=0 notes the disabled age check"
expect_not "$(cat "$FAKEOPKG_LOG")" '^update$' \
    "OPKG_MAXAGE=0 does not trigger opkg update"

# Column name override
# shellcheck disable=SC2086
out=$(OPKG_COLUMN=pkg $TESTSH "$REPO/extensions/opkg/opkg.sh")
expect "$out" '^status testhost\.pkg ' \
    "column name is overridable via OPKG_COLUMN"

# "opkg list-upgradable" fails -> yellow
# shellcheck disable=SC2086
out=$(FAKEOPKG_LIST_RC=1 $TESTSH "$REPO/extensions/opkg/opkg.sh")
expect "$out" '^status testhost\.opkg yellow ' \
    "failed list-upgradable reports yellow"
expect "$out" 'list-upgradable" failed' \
    "failed list-upgradable note present"

# No opkg binary at all -> clear
# shellcheck disable=SC2086
out=$(OPKG_CFG="$TESTDIR/opkg/opkg_test_noopkg.cfg" \
    $TESTSH "$REPO/extensions/opkg/opkg.sh")
expect "$out" '^status testhost\.opkg clear ' \
    "missing opkg reports clear, not red"
expect "$out" 'opkg not found' "missing opkg hint present"

unset OPKG_CFG FAKEOPKG_LOG

# ----------------------------------------------------------------------
echo "--- wifi ---"
export FAKEIW="$TESTDIR/wifi/fakeiw"
export FAKEUBUS="$TESTDIR/wifi/fakeubus"
export FAKEIWINFO="$TESTDIR/wifi/fakeiwinfo"
export FAKESYSNET="$TESTDIR/wifi/sysnet"
export WIFI_CFG="$TESTDIR/wifi/wifi_test.cfg"
unset FAKEIW_DEV FAKEIW_SURVEY FAKEIW_STATION FAKEIW_FAIL \
    FAKEUBUS_JSON FAKEUBUS_FAIL 2>/dev/null || true
rm -f "$TMP"/wifi.*.state

# First poll: gauges only - the rates need two polls
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/wifi/wifi.sh")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: wifi.sh exited with $rc"
    printf '%s\n' "$out"
    exit 1
fi
expect "$out" '^status testhost\.wifi green ' \
    "first poll reports green (info-only extension)"
expect "$out" 'wifi: 8 client\(s\) on 4 AP interface\(s\)' \
    "summary line carries the client and interface count"
expect "$out" '^data testhost\.wifi$' "data message for the RRDs is sent"
expect "$out" '^clients_phy0_ap0 : 5$' \
    "client count from hostapd get_clients (authorized only)"
expect "$out" 'clients=5 \[hostapd\]' \
    "status names hostapd as the client source (key=value style)"
expect "$out" '^clients_phy1_ap0 : 3$' \
    "iwinfo assoclist fallback when hostapd has no such interface"
expect "$out" '^clients_phy1_ap1 : 0$' \
    "\"No station connected\" counts as zero clients"
expect "$out" '^clients_total : 8$' "total client count summed"
expect "$out" '^channel_phy0 : 36$' "channel per radio extracted from iw dev"
expect "$out" '^channel_phy1 : 6$'  "second radio channel extracted"
expect "$out" '^noise_phy0 : -99$' \
    "noise floor from the in-use survey block"
expect_not "$out" '^(rxkbps|txkbps|airrx|airtx|retries|failed|busy|rxpct|txpct)_' \
    "no rate metrics on the first poll"
expect_not "$out" 'phy0-ap0 :' \
    "NCV names are sanitized (no raw interface names with dashes)"
if grep -q '^IF phy0-ap0 ' "$TMP/wifi.testhost.state" 2>/dev/null \
    && grep -q '^PHY phy0 ' "$TMP/wifi.testhost.state" 2>/dev/null; then
    echo "ok:   state file primed with IF and PHY counter lines"
else
    echo "FAIL: state file missing or incomplete ($TMP/wifi.testhost.state)"
    FAIL=1
fi

# Second poll: state from ~5 minutes ago with counters chosen for
# round deltas - 30 MB rx / 3 MB tx in 300 s, 30 s airtime rx /
# 15 s tx, 3 retries / 30 failures, and a survey delta of
# 300000/60000/3000/30000 ms (active/busy/rx/tx).
T0=$(($(date +%s) - 300))
{
    printf 'PHY phy0 %s 976570758 15899425 545578 12063957\n' "$T0"
    printf 'IF phy0-ap0 %s 2370000000 11997000000 87570512 416557494 24361 165\n' "$T0"
} > "$TMP/wifi.testhost.state"
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/wifi/wifi.sh")
expect_rate "$out" rxkbps_phy0_ap0 800.0 \
    "rx throughput from the sysfs byte counter delta"
expect_rate "$out" txkbps_phy0_ap0 80.0 \
    "tx throughput from the sysfs byte counter delta"
expect_rate "$out" airrx_phy0_ap0 10.0 \
    "rx airtime percent from the summed hostapd airtime delta"
expect_rate "$out" airtx_phy0_ap0 5.0 \
    "tx airtime percent from the summed hostapd airtime delta"
expect_rate "$out" retries_phy0_ap0 0.01 \
    "tx retry rate from the station dump delta"
expect_rate "$out" failed_phy0_ap0 0.10 \
    "tx failure rate from the station dump delta"
expect "$out" '^busy_phy0 : 20\.0$' \
    "channel busy percent from the survey delta"
expect "$out" '^rxpct_phy0 : 1\.0$'  "channel receive percent"
expect "$out" '^txpct_phy0 : 10\.0$' "channel transmit percent"
expect "$out" 'rx=[0-9]+\.[0-9] tx=[0-9]+\.[0-9] kbit/s' \
    "status shows the throughput (key=value style)"

# Counter reset (reboot): every previous counter is larger than the
# current one - the rates must be skipped, never reported negative
{
    printf 'PHY phy0 %s 976870759 99999999999 999999999 999999999\n' "$T0"
    printf 'IF phy0-ap0 %s 9999999999999 99999999999999 999999999 999999999 9999999 99999\n' "$T0"
} > "$TMP/wifi.testhost.state"
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/wifi/wifi.sh")
expect "$out" '^status testhost\.wifi green ' \
    "counter reset does not degrade the column"
expect_not "$out" '^(rxkbps|txkbps|airrx|airtx|retries|failed)_phy0_ap0' \
    "no interface rates after a counter reset"
expect_not "$out" '^(busy|rxpct|txpct)_phy0' \
    "no channel utilization after a survey counter reset"
expect_not "$out" 'implausible' \
    "a counter reset/wrap is skipped silently, not called out"
expect_not "$out" '^(rxkbps|txkbps|airrx|airtx|retries|failed|busy|rxpct|txpct|clients|channel)[a-z0-9_]* : -' \
    "no negative values in any rate or count metric"
expect "$out" '^clients_total : 8$' \
    "gauge metrics survive a counter reset"

# Garbage absolute survey counters (seen on a Zyxel NWA50AX Pro,
# mt798x: busy/rx/tx carry a huge constant offset while the deltas are
# fine) and a client with auth=true but authorized=false - it must not
# be counted. First poll: primes the state, no complaint, no metrics.
rm -f "$TMP"/wifi.*.state
# shellcheck disable=SC2086
out=$(FAKEIW_DEV="$TESTDIR/wifi/data/iw_dev.nwa.txt" \
    FAKEIW_SURVEY="$TESTDIR/wifi/data/survey.garbage.txt" \
    FAKEUBUS_JSON="$TESTDIR/wifi/data/hostapd.badclient.json" \
    $TESTSH "$REPO/extensions/wifi/wifi.sh")
expect "$out" '^status testhost\.wifi green ' \
    "garbage absolute survey counters do not degrade the column"
expect_not "$out" 'implausible' \
    "no implausible complaint while priming the state"
expect_not "$out" '^(busy|rxpct|txpct)_' \
    "no channel utilization on the first poll"
expect "$out" '^noise_phy0 : -91$' \
    "noise floor is still reported (that value is sane)"
expect "$out" '^channel_phy0 : 1$' "NWA 2.4 GHz radio channel extracted"
expect "$out" '^clients_phy0_ap0 : 0$' \
    "auth=true but authorized=false client is not counted"
expect "$out" '^clients_total : 0$' "total is zero on the idle NWA"

# Second poll on the NWA: previous counters = current garbage values
# minus round deltas (active/busy/rx/tx = 300000/60000/3000/30000 ms)
# - the utilization must come out of the deltas despite the absolute
# garbage (busy/rx/tx way beyond the active time, rx/tx beyond 2^53)
T0=$(($(date +%s) - 300))
printf 'PHY phy0 %s 3635159991 2685914092659807 12142113357313468 16980392843074179\n' \
    "$T0" > "$TMP/wifi.testhost.state"
# shellcheck disable=SC2086
out=$(FAKEIW_DEV="$TESTDIR/wifi/data/iw_dev.nwa.txt" \
    FAKEIW_SURVEY="$TESTDIR/wifi/data/survey.garbage.txt" \
    FAKEUBUS_JSON="$TESTDIR/wifi/data/hostapd.badclient.json" \
    $TESTSH "$REPO/extensions/wifi/wifi.sh")
expect "$out" '^busy_phy0 : 20\.0$' \
    "channel busy percent from deltas of garbage absolute counters"
expect "$out" '^rxpct_phy0 : 1\.0$' \
    "channel receive percent despite counters beyond 2^53"
expect "$out" '^txpct_phy0 : 10\.0$' \
    "channel transmit percent despite counters beyond 2^53"
expect "$out" 'busy=20\.0% rx=1\.0% tx=10\.0%' \
    "status shows the utilization on the NWA"
expect_not "$out" 'implausible' \
    "plausible deltas silence the implausible complaint"

# Implausible deltas (busy grew by 400000 ms in 300000 ms of active
# time): utilization suppressed and called out, column stays green
printf 'PHY phy0 %s 3635159991 2685914092319807 12142113357313468 16980392843074179\n' \
    "$T0" > "$TMP/wifi.testhost.state"
# shellcheck disable=SC2086
out=$(FAKEIW_DEV="$TESTDIR/wifi/data/iw_dev.nwa.txt" \
    FAKEIW_SURVEY="$TESTDIR/wifi/data/survey.garbage.txt" \
    FAKEUBUS_JSON="$TESTDIR/wifi/data/hostapd.badclient.json" \
    $TESTSH "$REPO/extensions/wifi/wifi.sh")
expect "$out" '^status testhost\.wifi green ' \
    "implausible survey deltas do not degrade the column"
expect "$out" 'survey counter deltas implausible' \
    "implausible survey deltas are called out in the status"
expect_not "$out" '^(busy|rxpct|txpct)_' \
    "no channel utilization from implausible deltas"

# ubus/hostapd unavailable: client counts fall back to iwinfo,
# airtime is unavailable, sysfs throughput keeps working
T0=$(($(date +%s) - 300))
{
    printf 'PHY phy0 %s 976570758 15899425 545578 12063957\n' "$T0"
    printf 'IF phy0-ap0 %s 2370000000 11997000000 87570512 416557494 24361 165\n' "$T0"
} > "$TMP/wifi.testhost.state"
# shellcheck disable=SC2086
out=$(FAKEUBUS_FAIL=1 $TESTSH "$REPO/extensions/wifi/wifi.sh")
expect "$out" '^clients_phy0_ap0 : 5$' \
    "client count via the iwinfo fallback"
expect "$out" 'clients=5 \[iwinfo\]' \
    "status names iwinfo as the client source"
expect_not "$out" '^air(rx|tx)_' \
    "no airtime metrics without hostapd"
expect_rate "$out" rxkbps_phy0_ap0 800.0 \
    "sysfs throughput unaffected by the missing ubus"

# Interface whitelist
rm -f "$TMP"/wifi.*.state
# shellcheck disable=SC2086
out=$(WIFI_INTERFACES="phy0-ap0" $TESTSH "$REPO/extensions/wifi/wifi.sh")
expect "$out" '^clients_total : 5$' \
    "WIFI_INTERFACES limits the monitored interfaces"
expect_not "$out" 'clients_phy1' \
    "unlisted interfaces are skipped entirely"

# No iw installed -> clear
# shellcheck disable=SC2086
out=$(WIFI_CFG="$TESTDIR/wifi/wifi_test_noiw.cfg" \
    $TESTSH "$REPO/extensions/wifi/wifi.sh")
expect "$out" '^status testhost\.wifi clear ' "missing iw reports clear"
expect "$out" 'iw not found'                  "missing iw hint present"

# No AP-mode interfaces -> clear
# shellcheck disable=SC2086
out=$(FAKEIW_DEV=/dev/null $TESTSH "$REPO/extensions/wifi/wifi.sh")
expect "$out" '^status testhost\.wifi clear ' \
    "no AP interfaces reports clear, not red"
expect "$out" 'no AP-mode wireless interfaces' "no-AP hint present"

# Column name override
rm -f "$TMP"/wifi.*.state
# shellcheck disable=SC2086
out=$(WIFI_COLUMN=wlan $TESTSH "$REPO/extensions/wifi/wifi.sh")
expect "$out" '^status testhost\.wlan green ' \
    "column name is overridable via WIFI_COLUMN"

unset WIFI_CFG

# ----------------------------------------------------------------------
echo "--- if_link ---"
# The fake sysfs tree mirrors a Turris Omnia (mvebu, DSA switch ports
# lan0..lan4, unused SFP eth0 administratively down) plus a wireless
# AP, bridges, a docker veth and the usual non-Ethernet devices.
export FAKESYSNET_LINK="$TESTDIR/if_link/sysnet"
export IF_LINK_CFG="$TESTDIR/if_link/if_link_test.cfg"
unset IF_LINK_INTERFACES IF_LINK_EXCLUDE IF_LINK_WIRELESS \
    IF_LINK_VIRTUAL IF_LINK_YELLOW IF_LINK_RED IF_LINK_THRESHOLDS \
    2>/dev/null || true
LINKSTATE="$TMP/if_link.testhost.state"
rm -f "$LINKSTATE"

# First poll: primes the state, no deltas yet
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/if_link/if_link.sh")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: if_link.sh exited with $rc"
    printf '%s\n' "$out"
    exit 1
fi
expect "$out" '^status testhost\.if_link green ' \
    "first poll reports green (no thresholds configured)"
expect "$out" 'if_link: 9 interface\(s\) monitored' \
    "auto-detection finds the nine physical Ethernet ports"
expect_not "$out" '^data testhost\.if_link$' \
    "no data message on the first poll - there is no delta yet"
expect "$out" '&green lan3  link=up  speed=1000Mb/full  master=br-iot .*total=161' \
    "port line carries link state, speed/duplex, bridge and the cumulative counter"
expect "$out" '&clear eth0  link=admin-down' \
    "administratively down port is marked, not counted as a fault"
expect "$out" '&green eth3 .*total=5' \
    "carrier_up_count + carrier_down_count fallback for kernels without carrier_changes"
expect "$out" '&green lan2  link=down  operstate=lowerlayerdown' \
    "a port that never had a link shows its operstate"
expect_not "$out" '^&[a-z]+ (lo|sit0|ip6tnl0) ' \
    "loopback and tunnel devices are not monitored"
expect_not "$out" '^&[a-z]+ (br-lan|br-iot|docker0|vethpVH4oZ) ' \
    "bridges and veth pairs are not monitored by default"
expect_not "$out" '^&[a-z]+ phy[01]-ap' \
    "wireless interfaces are not monitored by default"
expect_not "$out" '^&[a-z]+ eth9 ' \
    "a port without any link change counter is skipped silently"
if grep -q '^IF lan3 [0-9][0-9]* 161$' "$LINKSTATE" 2>/dev/null; then
    echo "ok:   state file primed with the cumulative counters"
else
    echo "FAIL: state file missing or incomplete ($LINKSTATE)"
    FAIL=1
fi

# Previous poll, 5 minutes ago: lan0 has gained 4 changes (two flaps)
# since then, everything else is unchanged, and lan3's counter went
# backwards (reboot). Every run below rewrites this state first - the
# extension replaces it with the current counters on each poll.
link_prev_state() {
    lps_t0=$(($(date +%s) - 300))
    {
        printf 'IF eth0 %s 0\n'   "$lps_t0"
        printf 'IF eth1 %s 1\n'   "$lps_t0"
        printf 'IF eth2 %s 0\n'   "$lps_t0"
        printf 'IF eth3 %s 5\n'   "$lps_t0"
        printf 'IF lan0 %s 4\n'   "$lps_t0"
        printf 'IF lan1 %s 1\n'   "$lps_t0"
        printf 'IF lan2 %s 0\n'   "$lps_t0"
        printf 'IF lan3 %s 999\n' "$lps_t0"
        printf 'IF lan4 %s 1\n'   "$lps_t0"
    } > "$LINKSTATE"
}

link_prev_state
# shellcheck disable=SC2086
out=$($TESTSH "$REPO/extensions/if_link/if_link.sh")
expect "$out" '^status testhost\.if_link green ' \
    "link changes alone do not color the column"
expect "$out" 'if_link: 4 link change\(s\) on 1 of 9 interface\(s\)' \
    "summary counts the changes and the affected interfaces"
expect "$out" '^data testhost\.if_link$' "data message for the RRDs is sent"
expect "$out" '^changes_lan0 : 4$' \
    "delta of the kernel counter reaches the RRD"
expect "$out" '^changes_lan1 : 0$' \
    "a stable port reports zero, so the graph has a value"
expect "$out" 'changes=\+4  total=8' \
    "status shows delta and cumulative counter (key=value style)"
# 300 or 301: the fixture timestamp and the extension read the clock a
# moment apart, so a second boundary in between must not fail the test.
expect "$out" '\(30[01] s ago\)' "footer names the age of the previous poll"
expect_not "$out" '^changes_[a-z0-9_]* : -' \
    "no negative value ever reaches the RRD"
expect "$out" 'lan3 .*changes=n/a\(counter reset\)' \
    "a counter that went backwards (reboot) is skipped for one poll"
expect_not "$out" '^changes_lan3 : ' \
    "no metric for the interface whose counter was reset"
expect_not "$out" '^changes_(lo|br_lan|docker0|phy0_ap0) : ' \
    "only the monitored interfaces produce metrics"

# The NCV parser treats "=" like ":", so the human-readable port lines
# must be fenced off - otherwise every "link=up" would become an RRD
# dataset of its own.
view=$(ncv_view "$out")
expect "$view" '^changes_lan0 : 4$' \
    "the data message stays visible to the server's parser"
expect_not "$view" '=' \
    "no '=' line reaches the NCV parser (display lines are fenced off)"

# Thresholds: global yellow, per-interface red, and an override that
# switches alerting off again for a single port
link_prev_state
# shellcheck disable=SC2086
out=$(IF_LINK_YELLOW=2 $TESTSH "$REPO/extensions/if_link/if_link.sh")
expect "$out" '^status testhost\.if_link yellow ' \
    "IF_LINK_YELLOW turns the column yellow above the limit"
expect "$out" '&yellow lan0 .*\[yellow at >=2\]' \
    "the offending port names the threshold it crossed"
expect "$out" '&green lan1 ' \
    "ports below the threshold stay green"
link_prev_state
# shellcheck disable=SC2086
out=$(IF_LINK_YELLOW=2 IF_LINK_THRESHOLDS="lan0:1:3" \
    $TESTSH "$REPO/extensions/if_link/if_link.sh")
expect "$out" '^status testhost\.if_link red ' \
    "IF_LINK_THRESHOLDS raises the per-interface limit to red"
expect "$out" '&red lan0 .*\[red at >=3\]' "red limit named on the port line"
link_prev_state
# shellcheck disable=SC2086
out=$(IF_LINK_YELLOW=2 IF_LINK_THRESHOLDS="lan*::" \
    $TESTSH "$REPO/extensions/if_link/if_link.sh")
expect "$out" '^status testhost\.if_link green ' \
    "an empty per-interface entry switches alerting off for those ports"
link_prev_state
# shellcheck disable=SC2086
out=$(IF_LINK_YELLOW=2 IF_LINK_EXCLUDE="lan0" \
    $TESTSH "$REPO/extensions/if_link/if_link.sh")
expect "$out" '^status testhost\.if_link green ' \
    "IF_LINK_EXCLUDE keeps a known-flapping port out entirely"
expect_not "$out" '^changes_lan0 : ' "excluded port produces no metric"

# Explicit interface list: patterns allowed, kind filters bypassed,
# and a named port without a counter is reported instead of dropped
rm -f "$LINKSTATE"
# shellcheck disable=SC2086
out=$(IF_LINK_INTERFACES="lan* eth9 br-lan" \
    $TESTSH "$REPO/extensions/if_link/if_link.sh")
expect "$out" 'if_link: 6 interface\(s\) monitored' \
    "IF_LINK_INTERFACES limits and expands the list by glob"
expect "$out" '&green br-lan ' \
    "a bridge named explicitly is monitored despite the virtual filter"
expect "$out" '&clear eth9  no link change counter' \
    "a named port without a counter is called out"
expect_not "$out" '^&[a-z]+ eth1 ' "unlisted ports are skipped"

# Wireless and virtual interfaces can be switched on
rm -f "$LINKSTATE"
# shellcheck disable=SC2086
out=$(IF_LINK_WIRELESS=yes IF_LINK_VIRTUAL=yes IF_LINK_EXCLUDE="veth* docker*" \
    $TESTSH "$REPO/extensions/if_link/if_link.sh")
expect "$out" '&green phy0-ap0 ' "IF_LINK_WIRELESS includes the AP interfaces"
expect "$out" '&green br-lan '   "IF_LINK_VIRTUAL includes the bridges"
expect_not "$out" '^&[a-z]+ (vethpVH4oZ|docker0) ' \
    "container interfaces stay out via IF_LINK_EXCLUDE"
T0=$(($(date +%s) - 300))
printf 'IF phy0-ap0 %s 0\n' "$T0" > "$LINKSTATE"
# shellcheck disable=SC2086
out=$(IF_LINK_WIRELESS=yes $TESTSH "$REPO/extensions/if_link/if_link.sh")
expect "$out" '^changes_phy0_ap0 : 2$' \
    "NCV names are sanitized (no raw interface names with dashes)"
expect_not "$out" 'phy0-ap0 :' "no unsanitized metric name in the data message"

# No interface matches -> clear, not red
rm -f "$LINKSTATE"
# shellcheck disable=SC2086
out=$(IF_LINK_INTERFACES="nosuchif0" $TESTSH "$REPO/extensions/if_link/if_link.sh")
expect "$out" '^status testhost\.if_link clear ' \
    "an empty interface list reports clear, not red"
expect "$out" 'no interface matches IF_LINK_INTERFACES' "hint names the setting"

# No sysfs at all (FreeBSD) -> clear
# shellcheck disable=SC2086
out=$(FAKESYSNET_LINK="$TMP/no-such-sysfs" \
    $TESTSH "$REPO/extensions/if_link/if_link.sh")
expect "$out" '^status testhost\.if_link clear ' \
    "a host without the sysfs counters reports clear"

# Column name override
rm -f "$LINKSTATE"
# shellcheck disable=SC2086
out=$(IF_LINK_COLUMN=iflink $TESTSH "$REPO/extensions/if_link/if_link.sh")
expect "$out" '^status testhost\.iflink green ' \
    "column name is overridable via IF_LINK_COLUMN"

rm -f "$LINKSTATE"
unset IF_LINK_CFG FAKESYSNET_LINK

# ----------------------------------------------------------------------
echo "--- xymonext ---"

# Install tree for the measurement wrapper plus fake extensions that
# behave like a real one (report through $XYMON, burn a little CPU,
# return an exit code) - the wrapper must run them unchanged.
XEDIR="$TMP/xymonext"
mkdir -p "$XEDIR/ext" "$XEDIR/etc" "$XEDIR/tmp"
cp "$REPO/extensions/xymonext/xymonext.sh" "$XEDIR/ext/"
cp "$REPO/extensions/xymonext/xymonext-send.sh" "$XEDIR/ext/"

cat > "$XEDIR/ext/fake.sh" <<'EOF'
#!/bin/sh
awk 'BEGIN { for (i = 0; i < 500000; i++) x += i }'
if [ -n "${XYMON:-}" ] && [ -n "${XYMSRV:-}" ]; then
    "$XYMON" "$XYMSRV" "status ${MACHINE}.fake green fake report"
else
    echo "status ${MACHINE}.fake green fake report"
fi
exit "${FAKE_RC:-0}"
EOF

# Sends its message on stdin, the other calling convention of the
# xymon client ("-" for xymon-send.sh, "@" for the xymon binary).
cat > "$XEDIR/ext/fakein.sh" <<'EOF'
#!/bin/sh
printf 'status %s.fakein green via stdin\n' "$MACHINE" | "$XYMON" "$XYMSRV" -
EOF

# Takes a full second, so the wall clock really has something to see.
cat > "$XEDIR/ext/slowfake.sh" <<'EOF'
#!/bin/sh
sleep 1
"$XYMON" "$XYMSRV" "status ${MACHINE}.slowfake green slow"
EOF

# Fake xymon client: records every message instead of sending it.
cat > "$XEDIR/fakexymon" <<'EOF'
#!/bin/sh
if [ "${2:-}" = "-" ] || [ "${2:-}" = "@" ]; then
    cat >> "${XE_CAPTURE:?}"
else
    printf '%s\n' "$2" >> "${XE_CAPTURE:?}"
fi
EOF
chmod +x "$XEDIR/ext/fake.sh" "$XEDIR/ext/fakein.sh" \
    "$XEDIR/ext/slowfake.sh" "$XEDIR/fakexymon"

XE_OLDTMP="$XYMONTMP"
export XYMONHOME="$XEDIR"
export XYMONTMP="$XEDIR/tmp"
export XYMON="$XEDIR/fakexymon"
export XYMSRV="127.0.0.1"
export XE_CAPTURE="$XEDIR/capture"

# --- a normal measured run --------------------------------------------
: > "$XE_CAPTURE"
# shellcheck disable=SC2086
$TESTSH "$XEDIR/ext/xymonext.sh" fake
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "ok:   xymonext.sh exits 0 when the extension does"
else
    echo "FAIL: xymonext.sh exited with $rc"
    FAIL=1
fi
captured=$(cat "$XE_CAPTURE")
expect "$captured" '^status testhost\.fake green fake report$' \
    "the measured extension runs and reports unchanged"
expect "$captured" '^status testhost\.xymonext green ' \
    "xymonext sends its own status column"
expect "$captured" '^data testhost\.xymonext$' \
    "data message for the RRD graphs is sent"
expect "$captured" '^wall_fake : [0-9]+\.[0-9][0-9]$' \
    "wall clock time is reported for the measured extension"
expect "$captured" '^cpu_fake : [0-9]+\.[0-9][0-9]$' \
    "CPU time is reported for the measured extension"
expect "$captured" '&green fake +wall +[0-9]+\.[0-9][0-9]s' \
    "the status table has a line for the measured extension"
expect "$captured" '<!-- ncv_skipstart -->' \
    "the human-readable table is fenced off from the NCV parser"

# The byte count must be the real length of what the extension sent.
xe_msg="status testhost.fake green fake report"
expect "$captured" "^bytes_fake : $(( ${#xe_msg} + 1 ))\$" \
    "byte count matches the length of the message sent"
expect "$captured" '&green fake .* msgs +1 ' \
    "the number of messages is counted"

# --- messages sent on stdin -------------------------------------------
: > "$XE_CAPTURE"
# shellcheck disable=SC2086
$TESTSH "$XEDIR/ext/xymonext.sh" fakein
captured=$(cat "$XE_CAPTURE")
expect "$captured" '^status testhost\.fakein green via stdin$' \
    "the shim passes a message read from stdin through"
xe_msg="status testhost.fakein green via stdin"
expect "$captured" "^bytes_fakein : $(( ${#xe_msg} + 1 ))\$" \
    "a message sent on stdin is counted too"

# --- wall clock ---------------------------------------------------------
: > "$XE_CAPTURE"
# shellcheck disable=SC2086
$TESTSH "$XEDIR/ext/xymonext.sh" slowfake
expect "$(cat "$XE_CAPTURE")" '^wall_slowfake : [12]\.[0-9][0-9]$' \
    "a one second extension is measured as one second of wall clock"

# --- the other wall clock sources ---------------------------------------
# XYMONEXT_WALLSRC pins the source, so the paths for hosts without a
# readable /proc/uptime (FreeBSD) are covered here as well.
: > "$XE_CAPTURE"
# shellcheck disable=SC2086
XYMONEXT_WALLSRC="date" $TESTSH "$XEDIR/ext/xymonext.sh" slowfake
captured=$(cat "$XE_CAPTURE")
expect "$captured" '^wall_slowfake : [12]\.00$' \
    "the date fallback measures the wall clock in whole seconds"
expect "$captured" 'date \+%s \(1 s resolution only\)' \
    "the status names the coarse timing source"

if [ -x /usr/bin/time ]; then
    : > "$XE_CAPTURE"
    # shellcheck disable=SC2086
    XYMONEXT_WALLSRC="time" FAKE_RC=5 $TESTSH "$XEDIR/ext/xymonext.sh" fake
    rc=$?
    captured=$(cat "$XE_CAPTURE")
    expect "$captured" '^wall_fake : [0-9]+\.[0-9][0-9]$' \
        "/usr/bin/time -p delivers the wall clock (the FreeBSD path)"
    expect "$captured" '^cpu_fake : [0-9]+\.[0-9][0-9]$' \
        "/usr/bin/time -p delivers the CPU time"
    expect "$captured" '^status testhost\.fake green fake report$' \
        "the extension reports normally under /usr/bin/time"
    if [ "$rc" -eq 5 ]; then
        echo "ok:   the exit code survives the /usr/bin/time path"
    else
        echo "FAIL: expected exit code 5 through /usr/bin/time, got $rc"
        FAIL=1
    fi
else
    echo "ok:   (skipped) /usr/bin/time is not installed on this host"
fi

# --- exit code and thresholds -------------------------------------------
: > "$XE_CAPTURE"
# shellcheck disable=SC2086
FAKE_RC=3 $TESTSH "$XEDIR/ext/xymonext.sh" fake
rc=$?
if [ "$rc" -eq 3 ]; then
    echo "ok:   the exit code of the measured extension is passed back"
else
    echo "FAIL: expected exit code 3 from the measured extension, got $rc"
    FAIL=1
fi
captured=$(cat "$XE_CAPTURE")
expect "$captured" '^status testhost\.xymonext yellow ' \
    "a failing extension turns the column yellow"
expect "$captured" 'exit 3' "the failed run is marked in the table"

: > "$XE_CAPTURE"
# shellcheck disable=SC2086
XYMONEXT_WALL_WARN=0.01 XYMONEXT_WALL_CRIT=0.02 \
    $TESTSH "$XEDIR/ext/xymonext.sh" slowfake
expect "$(cat "$XE_CAPTURE")" '^status testhost\.xymonext red ' \
    "a run above XYMONEXT_WALL_CRIT turns the column red"

# --- ageing of the table ------------------------------------------------
printf '%s 0 0.10 0.05 1 100\n' "$(( $(date +%s) - 99999 ))" \
    > "$XYMONTMP/xymonext.d/oldext"
: > "$XE_CAPTURE"
# shellcheck disable=SC2086
$TESTSH "$XEDIR/ext/xymonext.sh" fake
captured=$(cat "$XE_CAPTURE")
expect_not "$captured" '&[a-z]+ oldext ' \
    "an extension that has not run for a long time drops out of the table"
expect "$captured" '&green fake ' "recent extensions stay in the table"
: > "$XE_CAPTURE"
# shellcheck disable=SC2086
XYMONEXT_MAXAGE=0 $TESTSH "$XEDIR/ext/xymonext.sh" fake
expect "$(cat "$XE_CAPTURE")" '&green oldext ' \
    "XYMONEXT_MAXAGE=0 keeps every entry in the table"
rm -f "$XYMONTMP/xymonext.d/oldext"

# --- switches -----------------------------------------------------------
: > "$XE_CAPTURE"
# shellcheck disable=SC2086
XYMONEXT_ENABLE=no $TESTSH "$XEDIR/ext/xymonext.sh" fake
captured=$(cat "$XE_CAPTURE")
expect "$captured" '^status testhost\.fake green fake report$' \
    "XYMONEXT_ENABLE=no still runs the extension"
expect_not "$captured" 'xymonext' \
    "XYMONEXT_ENABLE=no reports nothing of its own"

: > "$XE_CAPTURE"
# shellcheck disable=SC2086
XYMONEXT_COUNT_BYTES=no $TESTSH "$XEDIR/ext/xymonext.sh" fake
captured=$(cat "$XE_CAPTURE")
expect "$captured" '^wall_fake : ' \
    "XYMONEXT_COUNT_BYTES=no still measures the times"
expect_not "$captured" '^bytes_fake : ' \
    "XYMONEXT_COUNT_BYTES=no reports no traffic"

: > "$XE_CAPTURE"
# shellcheck disable=SC2086
XYMONEXT_COLUMN=extcost $TESTSH "$XEDIR/ext/xymonext.sh" fake
expect "$(cat "$XE_CAPTURE")" '^status testhost\.extcost green ' \
    "column name is overridable via XYMONEXT_COLUMN"

# --- configuration file -------------------------------------------------
cat > "$XEDIR/etc/xymonext.cfg" <<'EOF'
XYMONEXT_COLUMN="fromcfg"
EOF
: > "$XE_CAPTURE"
# shellcheck disable=SC2086
$TESTSH "$XEDIR/ext/xymonext.sh" fake
expect "$(cat "$XE_CAPTURE")" '^status testhost\.fromcfg green ' \
    "settings are read from \$XYMONHOME/etc/xymonext.cfg"
rm -f "$XEDIR/etc/xymonext.cfg"

# --- usage errors -------------------------------------------------------
# shellcheck disable=SC2086
out=$($TESTSH "$XEDIR/ext/xymonext.sh" --help)
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "ok:   --help exits 0"
else
    echo "FAIL: --help exited with $rc"
    FAIL=1
fi
expect "$out" 'usage: .*EXTENSION' "--help prints the usage"

# shellcheck disable=SC2086
if $TESTSH "$XEDIR/ext/xymonext.sh" nosuchext 2>/dev/null; then
    echo "FAIL: an unknown extension should fail"
    FAIL=1
else
    echo "ok:   an unknown extension reports an error"
fi

# shellcheck disable=SC2086
if $TESTSH "$XEDIR/ext/xymonext.sh" "../../etc/passwd" 2>/dev/null; then
    echo "FAIL: an extension name with a path should be rejected"
    FAIL=1
else
    echo "ok:   an extension name with a path is rejected"
fi

unset XE_CAPTURE XYMONHOME XYMON XYMSRV 2>/dev/null || true
export XYMONTMP="$XE_OLDTMP"

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
cp "$REPO/extensions/disk/disk.sh" "$STAGE/ext/disk.sh"
cp "$REPO/extensions/opkg/opkg.sh" "$STAGE/ext/opkg.sh"
# The measurement wrapper is installed like an extension, but the
# runner must call it instead of running it as a test of its own.
cp "$REPO/extensions/xymonext/xymonext.sh" "$STAGE/ext/xymonext.sh"
cp "$REPO/extensions/xymonext/xymonext-send.sh" "$STAGE/ext/xymonext-send.sh"
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
cat > "$STAGE/etc/disk.cfg" <<EOF
DISK_DF="$FAKEDF"
export FAKEDF_OUTPUT="$TESTDIR/disk/data/df-turris.txt"
EOF
# Fresh lists so opkg.sh neither calls "opkg update" nor warns
mkdir -p "$FAKEOPKG_LISTSDIR"
touch "$FAKEOPKG_LISTSDIR/base"
cat > "$STAGE/etc/opkg.cfg" <<EOF
OPKG_BIN="$FAKEOPKG"
OPKG_LISTSDIR="$FAKEOPKG_LISTSDIR"
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
expect "$captured" '^status turris,example,org\.mem green ' \
    "memory extension runs under the standalone runner, defaulted to column \"mem\""
expect "$captured" '^used : 50\.0$' \
    "memory NCV payload arrives, config read from \$XYMONHOME/etc"
expect "$captured" '^status turris,example,org\.disk green ' \
    "disk extension runs under the standalone runner"
expect "$captured" '% /srv$' \
    "disk df table arrives, config read from \$XYMONHOME/etc"
expect "$captured" '^status turris,example,org\.opkg green ' \
    "opkg extension runs under the standalone runner"
expect "$captured" '^updates : 0$' \
    "opkg NCV payload arrives, config read from \$XYMONHOME/etc"
expect "$captured" '^status turris,example,org\.xymonext ' \
    "the runner measures the extensions and reports the xymonext column"
expect "$captured" '^wall_smart : [0-9]+\.[0-9][0-9]$' \
    "xymonext graphs the runtime of an extension run by the runner"
expect "$captured" '^bytes_smart : [0-9]+$' \
    "xymonext counts the bytes sent through the standalone transport"
expect_not "$captured" '^wall_xymonext : ' \
    "the wrapper is not run as a test of its own"
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
expect_not "$captured" '^status turris,example,org\.(smart|mem|disk|opkg) ' \
    "TESTS: unlisted extensions do not run"

# Extensions named explicitly run even when not in TESTS
: > "$NC_CAPTURE"
# shellcheck disable=SC2086
PATH="$SBIN:$PATH" $TESTSH "$STAGE/xymon-run.sh" memory
expect "$(cat "$NC_CAPTURE")" '^status turris,example,org\.mem ' \
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

# ----------------------------------------------------------------------
echo "--- packaging ---"

# The server-side drop-in files (server/xymonserver.d, server/graphs.d,
# server/rrddefinitions.d) are shipped as documentation. Two things can
# drift apart silently, so pin both: stage.sh must install every one of
# them, and the FreeBSD pkg-plist must list exactly what stage.sh
# installs - pkg(8) fails the build on a plist/stage mismatch, but only
# on FreeBSD, i.e. long after the change was made.

PKGSTAGE="$TMP/pkgstage"
DOCROOT=/usr/share/doc/my-xymon-extensions

if (cd "$REPO" && sh packaging/common/stage.sh "$PKGSTAGE" \
        /ext /etc /etc/tasks.d "$DOCROOT" >/dev/null); then
    echo "ok:   stage.sh runs"
else
    echo "FAIL: stage.sh failed"
    FAIL=1
fi

# Every extension with a server/ directory ships a README and the
# xymonserver.d snippet, and every one of its files is staged.
for srvdir in "$REPO"/extensions/*/server; do
    [ -d "$srvdir" ] || continue
    ext=$(basename "$(dirname "$srvdir")")
    for want in "README.md" "xymonserver.d/$ext.cfg"; do
        if [ -f "$srvdir/$want" ]; then
            echo "ok:   $ext ships server/$want"
        else
            echo "FAIL: $ext has no server/$want"
            FAIL=1
        fi
    done
done

(cd "$REPO" && find extensions -type f) | grep '/server/' \
    | sed 's|^extensions/||' | sort > "$TMP/server-files"
while read -r rel; do
    if [ -f "$PKGSTAGE$DOCROOT/$rel" ]; then
        echo "ok:   stage.sh installs $rel"
    else
        echo "FAIL: stage.sh does not install extensions/$rel"
        FAIL=1
    fi
done < "$TMP/server-files"

# stage.sh <-> pkg-plist, both directions.
(cd "$PKGSTAGE$DOCROOT" && find . -type f) | sed 's|^\./||' | sort > "$TMP/staged-docs"
grep "^share/doc/my-xymon-extensions/" "$REPO/packaging/freebsd/pkg-plist" \
    | sed 's|^share/doc/my-xymon-extensions/||' | sort > "$TMP/plist-docs"
if cmp -s "$TMP/staged-docs" "$TMP/plist-docs"; then
    echo "ok:   pkg-plist lists exactly the staged documentation files"
else
    echo "FAIL: pkg-plist and stage.sh disagree about the documentation files"
    echo "      only staged:    $(grep -Fxv -f "$TMP/plist-docs" "$TMP/staged-docs" | tr '\n' ' ')"
    echo "      only in plist:  $(grep -Fxv -f "$TMP/staged-docs" "$TMP/plist-docs" | tr '\n' ' ')"
    FAIL=1
fi

# --- the server package ------------------------------------------------
# Same idea for stage-server.sh: it must install every drop-in file, and
# the deb conffiles list must name exactly the installed config files.

SRVSTAGE="$TMP/srvstage"
SRVETC=/etc/xymon
SRVDOC=/usr/share/doc/my-xymon-extensions-server

if (cd "$REPO" && sh packaging/common/stage-server.sh "$SRVSTAGE" \
        "$SRVETC" "$SRVDOC" >/dev/null); then
    echo "ok:   stage-server.sh runs"
else
    echo "FAIL: stage-server.sh failed"
    FAIL=1
fi

# Every drop-in file in the repo must be installed into the drop-in
# directory of the same name. (The server READMEs are documentation and
# are checked through the conffiles comparison below, not here.)
grep '/server/.*\.d/' "$TMP/server-files" | while read -r rel; do
    # rel = <ext>/server/<dropin>/<ext>.cfg -> <dropin>/<ext>.cfg
    dropin=${rel#*/server/}
    if [ -f "$SRVSTAGE$SRVETC/$dropin" ]; then
        echo "ok:   stage-server.sh installs $SRVETC/$dropin"
    else
        echo "FAIL: stage-server.sh does not install $SRVETC/$dropin"
        echo "$rel" >> "$TMP/srv-missing"
    fi
done
[ -f "$TMP/srv-missing" ] && FAIL=1

(cd "$SRVSTAGE" && find . -type f) | sed 's|^\.||' | grep "^$SRVETC/" \
    | sort > "$TMP/srv-etc"
sort < "$REPO/packaging/deb-server/conffiles" > "$TMP/srv-conffiles"
if cmp -s "$TMP/srv-etc" "$TMP/srv-conffiles"; then
    echo "ok:   deb-server conffiles lists exactly the installed config files"
else
    echo "FAIL: deb-server conffiles and stage-server.sh disagree"
    echo "      only staged:      $(grep -Fxv -f "$TMP/srv-conffiles" "$TMP/srv-etc" | tr '\n' ' ')"
    echo "      only in conffiles:$(grep -Fxv -f "$TMP/srv-etc" "$TMP/srv-conffiles" | tr '\n' ' ')"
    FAIL=1
fi

# On Debian/Ubuntu the client and the server both keep their config in
# /etc/xymon, so the two packages must not claim the same path - dpkg
# refuses to install packages that do. Stage both with the Debian paths
# and compare.
CLIENTSTAGE="$TMP/pkgstage-deb"
(cd "$REPO" && sh packaging/common/stage.sh "$CLIENTSTAGE" \
    /usr/lib/xymon/client/ext /etc/xymon /etc/xymon/tasks.d - >/dev/null)
(cd "$CLIENTSTAGE" && find . -type f) | sed 's|^\.||' | sort > "$TMP/client-paths"
(cd "$SRVSTAGE" && find . -type f) | sed 's|^\.||' | sort > "$TMP/server-paths"
overlap=$(grep -Fxf "$TMP/client-paths" "$TMP/server-paths" || true)
if [ -z "$overlap" ]; then
    echo "ok:   client and server package share no file path in /etc/xymon"
else
    echo "FAIL: client and server package both ship: $(echo "$overlap" | tr '\n' ' ')"
    FAIL=1
fi

# The server package does not edit the stock Xymon configs; its
# post-install tells the admin which drop-in directory is not read yet.
# Debian wires up xymonserver.d and graphs.d (via the include files its
# init script regenerates in /var/run/xymon), but ships no
# rrddefinitions.d - so exactly one TODO is the expected outcome there.
SRVPOSTINST="$REPO/packaging/deb-server/postinst"

XYMONETC="$TMP/xymonetc-debian"
mkdir -p "$XYMONETC"
printf 'TEST2RRD="x"\ninclude /var/run/xymon/xymonserver-include.cfg\n' \
    > "$XYMONETC/xymonserver.cfg"
printf '[la]\ninclude /var/run/xymon/graphs-include.cfg\n' > "$XYMONETC/graphs.cfg"
printf '[default]\n\tRRA:AVERAGE:0.5:1:576\n' > "$XYMONETC/rrddefinitions.cfg"
out=$(XYMONETCDIR="$XYMONETC" $TESTSH "$SRVPOSTINST" configure)
expect "$out" 'ok: +xymonserver\.cfg reads' "postinst: Debian xymonserver.d wiring detected"
expect "$out" 'ok: +graphs\.cfg reads' "postinst: Debian graphs.d wiring detected"
expect "$out" 'TODO: +rrddefinitions\.cfg does not read' \
    "postinst: missing rrddefinitions.d reported"
expect "$out" 'optional directory .*/rrddefinitions\.d' \
    "postinst: prints the line to add for rrddefinitions.d"
expect "$out" 'service xymon restart' "postinst: asks for a restart"

# A Xymon that reads none of the three: three TODOs, no crash.
XYMONETC="$TMP/xymonetc-bare"
mkdir -p "$XYMONETC"
printf 'TEST2RRD="x"\n' > "$XYMONETC/xymonserver.cfg"
out=$(XYMONETCDIR="$XYMONETC" $TESTSH "$SRVPOSTINST" configure)
expect "$out" 'TODO: +xymonserver\.cfg does not read' \
    "postinst: unwired xymonserver.d reported"
expect "$out" 'TODO: +graphs\.cfg does not read' \
    "postinst: missing graphs.cfg reported"
expect_not "$out" ' ok: ' "postinst: nothing reported as wired up"

# Any other dpkg action must be a no-op.
out=$(XYMONETCDIR="$TMP/xymonetc-bare" $TESTSH "$SRVPOSTINST" abort-upgrade 1.0)
expect_not "$out" '.' "postinst: silent for actions other than configure"

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
else
    echo "There were test failures."
fi
exit "$FAIL"
