#!/bin/sh
# Drive nfsserver-sampler.sh through scripted samples. A fake sleep moves
# a fixture /proc forward one line of a scenario per pass:
#   "uptime_cs io_read io_write rpc_calls", or "-" for nfsd being absent.
set -u
here=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
tmp=$(mktemp -d) || exit 1
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null; fi; rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM
sampler="$here/extensions/nfsserver/nfsserver-sampler.sh"
# The sleep binary itself: BusyBox's "command -v sleep" names its builtin.
FAKE_REALSLEEP=
oldifs=$IFS; IFS=:
for dir in $PATH; do
    if [ -z "$FAKE_REALSLEEP" ] && [ -x "$dir/sleep" ]; then FAKE_REALSLEEP=$dir/sleep; fi
done
IFS=$oldifs
[ -n "$FAKE_REALSLEEP" ] || { echo 'no sleep binary in PATH' >&2; exit 1; }
export FAKE_DIR="$tmp" FAKE_REALSLEEP FAKE_KERNEL=4.18.0-553.el8_10.x86_64
export MACHINE=nfstest XYMONTMP="$tmp" NFSSERVER_PROC="$tmp/proc"
export NFSSERVER_CFG="$tmp/monitor.cfg" NFSSERVER_SAMPLER_ANYPARENT=yes
# Not through PATH: BusyBox ash runs its sleep builtin.
export NFSSERVER_SAMPLER_SLEEP="$tmp/bin/sleep"
# Save on every 1 s sample unless a test says otherwise.
export NFSSERVER_SAMPLER_SAVE=1
: > "$NFSSERVER_CFG"
mkdir -p "$tmp/bin" "$tmp/proc/net/rpc" "$tmp/proc/sys/kernel/random" || exit 1
printf 'sampler-boot\n' > "$tmp/proc/sys/kernel/random/boot_id"
cat > "$tmp/bin/uname" <<'EOF'
#!/bin/sh
case "$1" in -r) printf '%s\n' "$FAKE_KERNEL" ;; -n) echo nfstest ;; *) echo Linux ;; esac
EOF
cat > "$tmp/bin/sleep" <<'EOF'
#!/bin/sh
# The probe for fractions of a second.
case "$1" in 0.01) exit "${FAKE_FRACTION_RC:-0}" ;; esac
pos=$(cat "$FAKE_DIR/pos") || exit 1
pos=$((pos + 1))
line=$(sed -n "${pos}p" "$FAKE_DIR/scenario")
# Scenario done: wait for real, so a running sampler does not spin.
[ -n "$line" ] || exec "$FAKE_REALSLEEP" 0.1
printf '%s\n' "$pos" > "$FAKE_DIR/pos"
if [ "$line" = - ]; then rm -f "$FAKE_DIR/proc/net/rpc/nfsd"; exit 0; fi
set -- $line
printf '%d.%02d 1.00\n' $(($1 / 100)) $(($1 % 100)) > "$FAKE_DIR/proc/uptime"
printf 'rc 0 0 0\nfh 0 0 0 0 0\nio %s %s\nth 8 0\nrpc %s 0 0 0 0\n' "$2" "$3" "$4" \
    > "$FAKE_DIR/proc/net/rpc/nfsd"
EOF
chmod +x "$tmp/bin/uname" "$tmp/bin/sleep" || exit 1
PATH="$tmp/bin:$PATH"
state="$tmp/nfsserver-nfstest"

fail() { echo "FAIL: nfsserver sampler: $1" >&2; cat "$tmp/log" >&2; exit 1; }
scenario() { # scenario LINE... - the first line is the state at the start
    rm -rf "$state"
    printf '%s\n' "$@" > "$tmp/scenario"
    printf '0\n' > "$tmp/pos"
    FAKE_FRACTION_RC=0 "$tmp/bin/sleep" 1
}
run() { # run PASSES [VAR=VALUE...] - take PASSES samples, then stop
    passes=$1; shift
    # shellcheck disable=SC2086 # CI supplies "busybox sh".
    env "$@" NFSSERVER_SAMPLER_LIMIT="$passes" ${TESTSH:-sh} "$sampler" > "$tmp/log" 2>&1
}
field() { awk -v k="$1" '$1 == k {print $2}' "$state/sampler"; }
expect() { # expect KEY VALUE
    [ "$(field "$1")" = "$2" ] || fail "$1 is '$(field "$1")', expected '$2'"
}
logs() { grep -q "$1" "$tmp/log" || fail "log lacks: $1"; }

# Increments and a wrap of the read counter between two 1 s samples.
scenario '100000 1000 2000 10' '100100 2000001000 2000002000 20' \
    '100200 1000 3000 30' '100300 1000 3000 40'
run 4 || fail 'exit status'
expect epoch 100000; expect gen 0; expect time 100300
expect read 4294967296; expect write 4294968296; expect step 1; expect boot sampler-boot
# The format nfsserver.awk reads (pinned there with the same keys).
expect version 1

# 1.5 s between two samples at 25 Gbit/s: one more wrap would have fitted.
scenario '100000 0 0 1' '100150 100 100 2'
run 2 || fail 'exit status'
expect gen 1; expect read 100

# Faster than SAMPLER_MAX_GBIT: the limit is too low to rule out a wrap.
scenario '100000 0 0 1' '100100 4000000000 0 2'
run 2 || fail 'exit status'
expect gen 1; logs 'traffic above SAMPLER_MAX_GBIT=25'

# Module reload: every counter back near 0, the RPC count far from 2^32.
scenario '100000 5000000 5000000 1000000' '100100 10 10 5'
run 2 || fail 'exit status'
expect epoch 100100; expect read 0; logs 'nfsd statistics were reset'

# The RPC call counter itself wraps: no reset.
scenario '100000 0 0 4294967000' '100100 10 20 100'
run 2 || fail 'exit status'
expect epoch 100000; expect read 10; expect write 20

# nfsd unloaded for a while: the totals are dropped, then start again.
scenario '100000 0 0 1' - '100200 50 50 3'
run 3 || fail 'exit status'
expect epoch 100200; expect read 0; logs 'totals dropped'

# Every SAMPLER_SAVE seconds, not on every sample.
scenario '100000 0 0 1' '100100 1 1 2' '100200 2 2 3'
run 3 NFSSERVER_SAMPLER_SAVE=2 || fail 'exit status'
expect time 100200
scenario '100000 0 0 1' '100100 1 1 2'
run 2 NFSSERVER_SAMPLER_SAVE=2 || fail 'exit status'
expect time 100000

# Half a second, and the fallback where sleep has no fractions.
scenario '100000 0 0 1' '100050 1 1 2'
run 2 NFSSERVER_SAMPLER_STEP=0.5 || fail 'exit status'
expect step 0.5; expect gen 0
scenario '100000 0 0 1'
run 1 FAKE_FRACTION_RC=1 NFSSERVER_SAMPLER_STEP=0.5 || fail 'exit status'
expect step 1; logs 'no fractions of a second'
scenario '100000 0 0 1'
if run 1 NFSSERVER_SAMPLER_STEP=2; then fail 'SAMPLER_STEP=2 accepted'; fi
logs 'SAMPLER_STEP must be 1 or 0.5'
if run 1 NFSSERVER_SAMPLER_MAX_GBIT=0; then fail 'SAMPLER_MAX_GBIT=0 accepted'; fi

# 64-bit kernel counters: nothing to sample, no state, no exit.
scenario '100000 0 0 1'
run 2 FAKE_KERNEL=5.14.0-503.el9.x86_64 || fail 'exit status'
logs 'nothing to sample'
[ ! -e "$state/sampler" ] || fail 'state written on a 64-bit kernel'

# Started by anything but xymonlaunch.
scenario '100000 0 0 1'
if run 1 NFSSERVER_SAMPLER_ANYPARENT=no; then fail 'ran without xymonlaunch'; fi
logs 'not started by xymonlaunch'

# A second sampler leaves the running one alone.
scenario '100000 0 0 1'
mkdir -m 700 "$state" || exit 1
(
    exec 8> "$state/sampler.lock" || exit 1
    flock -n 8 || exit 1
    run 1
) || fail 'exit status with the lock taken'
logs 'another sampler is running'

# TERM: the totals are only valid while the sampler runs.
scenario '100000 0 0 1'
# shellcheck disable=SC2086 # CI supplies "busybox sh".
${TESTSH:-sh} "$sampler" > "$tmp/log" 2>&1 &
pid=$!
n=0
while [ ! -e "$state/sampler" ] && [ "$n" -lt 100 ]; do "$FAKE_REALSLEEP" 0.1; n=$((n + 1)); done
[ -e "$state/sampler" ] || fail 'no state while running'
kill -TERM "$pid"
wait "$pid"
[ ! -e "$state/sampler" ] || fail 'state left behind after TERM'
logs 'terminated - stopping'

# The parent (xymonlaunch) goes away: the sampler stops by itself.
scenario '100000 0 0 1'
# shellcheck disable=SC2016 # expanded by the inner shell
${TESTSH:-sh} -c '$1 "$2" > "$3" 2>&1 & "$4" 1' parent "${TESTSH:-sh}" "$sampler" \
    "$tmp/log" "$FAKE_REALSLEEP"
n=0
while ! grep -q 'stopping' "$tmp/log" && [ "$n" -lt 100 ]; do "$FAKE_REALSLEEP" 0.1; n=$((n + 1)); done
logs 'xymonlaunch is gone - stopping'
[ ! -e "$state/sampler" ] || fail 'state left behind without a parent'

echo 'ok: nfsserver sampler: wraps, ambiguity, resets, parent, lock and TERM'
