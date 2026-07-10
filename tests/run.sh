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

# Status display must not contain NCV-style "name : value" lines other
# than in the data section (they would pollute the RRDs).
expect "$out" 'pending=8' "status section uses key=value, not key : value"

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
echo "--- standalone: xymon-run.sh + smart ---"

# Simulated install tree, as the opkg package would lay it out.
STAGE="$TMP/xymon-standalone"
mkdir -p "$STAGE/ext" "$STAGE/etc"
cp "$REPO/standalone/xymon-run.sh" "$REPO/standalone/xymon-send.sh" "$STAGE/"
cp "$REPO/extensions/smart/smart.sh" "$STAGE/ext/smart.sh"
cp "$TESTDIR/smart/smart_test.cfg" "$STAGE/etc/smart.cfg"
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
