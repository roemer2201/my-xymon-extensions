#!/bin/sh
# Unit tests for the extensions in this repository.
# Runs the scripts against canned command output - no real hardware,
# no Xymon server needed. Exit code 0 = all tests passed.
set -u

TESTDIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$TESTDIR")
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
unset XYMON XYMSRV 2>/dev/null || true

out=$(sh "$REPO/extensions/smart/smart.sh")
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
    "attrmap override works: temp from 190 (39), not 194 (38)"
expect "$out" '^tsda_pending : 8$'  "tsda pending extracted"
expect "$out" '^tsda_realloc : 0$'  "tsda realloc extracted"
expect "$out" '^tsda_hours : 20573$' "tsda power-on hours extracted"

# Data (NCV) values - SATA SSD (name-based mapping via drivedb names)
expect "$out" '^tssd_wear : 9$' \
    "SSD wear from Wear_Leveling_Count normalized value (100-91)"
expect "$out" '^tssd_temp : 31$'    "SSD temp from Airflow_Temperature_Cel"
expect_not "$out" 'tssd_[a-z]*ECC'  "unmapped attributes are not reported"

# Data (NCV) values - NVMe
expect "$out" '^tnvme0_temp : 41$'      "NVMe composite temperature"
expect "$out" '^tnvme0_wear : 3$'       "NVMe Percentage Used"
expect "$out" '^tnvme0_spare : 100$'    "NVMe Available Spare"
expect "$out" '^tnvme0_hours : 8760$'   "NVMe hours (comma separator removed)"
expect "$out" '^tnvme0_mediaerr : 0$'   "NVMe media errors"
expect "$out" '^tnvme0_unsafeshut : 42$' "NVMe unsafe shutdowns"

# Status display must not contain NCV-style "name : value" lines other
# than in the data section (they would pollute the RRDs).
expect "$out" 'pending=8' "status section uses key=value, not key : value"

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
else
    echo "There were test failures."
fi
exit "$FAIL"
