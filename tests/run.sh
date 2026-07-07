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

# ----------------------------------------------------------------------
echo ""
echo "--- diskio ---"
DISKIODIR="$TESTDIR/diskio"
mkdir -p "$TMP/proc"
export DISKIO_PROC="$TMP/proc"
export DISKIO_SYS="$DISKIODIR/data/sys"
export DISKIO_STATE="$TMP/diskio.state"
export DISKIO_CFG="$DISKIODIR/diskio_test.cfg"
export DISKIO_OS="Linux"
export ZPOOL="false"    # no ZFS pools in the Linux runs
unset XYMON XYMSRV 2>/dev/null || true

# Run 1: no state file yet -> baseline only, no data lines
cp "$DISKIODIR/data/diskstats-t0.txt" "$TMP/proc/diskstats"
out=$(DISKIO_NOW=1000000 sh "$REPO/extensions/diskio/diskio.sh")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: diskio.sh (run 1) exited with $rc"
    printf '%s\n' "$out"
    exit 1
fi
expect "$out" '^status testhost\.diskio green ' \
    "first run is green (baseline collection)"
expect "$out" '&clear pd_sda: baseline stored \(first run' \
    "baseline note for pd_sda"
expect_not "$out" 'pd_sda_rbps' "no data lines on the first run"

# Run 2: 300 s later with t1 counters -> exact interval averages
cp "$DISKIODIR/data/diskstats-t1.txt" "$TMP/proc/diskstats"
out=$(DISKIO_NOW=1000300 sh "$REPO/extensions/diskio/diskio.sh")
expect "$out" '^status testhost\.diskio green ' "second run is green"
expect "$out" '^pd_sda_rbps : 1048576$'  "sda read throughput (512-byte sectors, dt=300)"
expect "$out" '^pd_sda_wbps : 524288$'   "sda write throughput"
expect "$out" '^pd_sda_riops : 2\.0$'    "sda read IOPS"
expect "$out" '^pd_sda_wiops : 5\.0$'    "sda write IOPS"
expect "$out" '^pd_sda_rlat : 5\.00$'    "sda read latency (ms per op)"
expect "$out" '^pd_sda_wlat : 10\.00$'   "sda write latency"
expect "$out" '^pd_sda_util : 10\.0$'    "sda utilization"
expect "$out" '^pd_sda_qlen : 0\.50$'    "sda queue depth"
expect "$out" '^pd_nvme0n1_rlat : 0\.00$' \
    "idle reads give latency 0, not a division by zero"
expect "$out" '^pd_nvme0n1_wbps : 102400$' "nvme write throughput"
expect "$out" '^md_md0_riops : 1\.0$'    "md RAID instance reported"
expect "$out" '^md_md0_util : 0\.0$'     "md util 0 (kernel does not account it)"
expect "$out" '^lv_vg0_root_rbps : 25600$' \
    "LVM LV keyed by mapper name, not dm-0"
expect "$out" '^cr_cryptdata_riops : 1\.0$' \
    "dm-crypt mapping classified via CRYPT- uuid"
expect_not "$out" 'loop0' "loop devices excluded by default"
expect_not "$out" 'sda1'  "partitions are not monitored"

# Run 3: counters go backwards (reboot) -> re-baseline, no bogus rates
cp "$DISKIODIR/data/diskstats-t0.txt" "$TMP/proc/diskstats"
out=$(DISKIO_NOW=1000600 sh "$REPO/extensions/diskio/diskio.sh")
expect "$out" '^status testhost\.diskio green ' "reset run stays green"
expect "$out" 'counter reset detected' "counter reset detected and noted"
expect_not "$out" '^pd_sda_rbps :' "no rates computed from negative deltas"

# Run 4: simulated FreeBSD (gstat sample) plus ZFS pools (zpool iostat)
export DISKIO_OS="FreeBSD"
export GSTAT="$DISKIODIR/fakegstat"
export ZPOOL="$DISKIODIR/fakezpool"
out=$(sh "$REPO/extensions/diskio/diskio.sh")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: diskio.sh (run 4) exited with $rc"
    printf '%s\n' "$out"
    exit 1
fi
expect "$out" '^status testhost\.diskio green ' "FreeBSD run is green"
expect "$out" '^pd_ada0_rbps : 1048576$'  "ada0 read throughput (kBps * 1024)"
expect "$out" '^pd_ada0_rlat : 2\.50$'    "ada0 read latency from ms/r"
expect "$out" '^pd_ada0_util : 42\.1$'    "ada0 utilization from %busy"
expect "$out" '^gm_gm0_wbps : 131072$'    "GEOM mirror instance (prefix stripped)"
expect "$out" '^gm_gm0_qlen : 1\.00$'     "GEOM mirror queue depth from L(q)"
expect "$out" '^zp_tank_riops : 200\.0$'  "zpool IOPS from the second sample block"
expect "$out" '^zp_tank_rbps : 20971520$' "zpool read bandwidth"
expect "$out" '^zp_tank_rlat : 3\.00$'    "zpool read latency (total_wait ns -> ms)"
expect "$out" '^zp_tank_wlat : 5\.00$'    "zpool write latency"
expect "$out" '^zp_empty_rlat : 0\.00$'   "idle pool: '-' latency becomes 0"
expect_not "$out" 'ada0p1' "partitions/slices skipped on FreeBSD"
expect_not "$out" 'cd0'    "non-disk providers skipped on FreeBSD"

# Run 5: same data with thresholds -> yellow with violation details
export DISKIO_CFG="$DISKIODIR/diskio_test_thr.cfg"
out=$(sh "$REPO/extensions/diskio/diskio.sh")
expect "$out" '^status testhost\.diskio yellow ' \
    "threshold violation turns the column yellow"
expect "$out" '&yellow pd_ada0: util=42\.1 \(warn 40 / crit 90\)' \
    "utilization violation reported with limits"
expect "$out" '&yellow zp_tank: riops=200\.0 \(warn 100 / crit -\)' \
    "warn-only threshold ('-' crit) reports yellow"

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
else
    echo "There were test failures."
fi
exit "$FAIL"
