#!/bin/sh
#
# xymonext-send.sh -- byte counting shim in front of the xymon client
#
# xymonext.sh exports this script as $XYMON while it runs an extension
# under measurement. The shim records the size of every message the
# extension sends and then hands the message over to the real client
# unchanged, so the extension cannot tell the difference.
#
# usage: xymonext-send.sh SERVER[:PORT] MESSAGE
#        xymonext-send.sh SERVER[:PORT] -           (message on stdin)
#
# Environment (set by xymonext.sh, all required):
#   XYMONEXT_XYMON     the real $XYMON to hand the message over to
#   XYMONEXT_BYTES     file collecting one byte count per message
#   XYMONEXT_WORKDIR   scratch directory of the measured run
#
# Without that environment the shim is a plain pass-through, so a
# stale export can never break an extension's reporting.
set -u

if [ $# -lt 2 ]; then
    echo "usage: $0 SERVER[:PORT] MESSAGE|-" >&2
    exit 2
fi

REAL="${XYMONEXT_XYMON:-}"
COUNTFILE="${XYMONEXT_BYTES:-}"
WORKDIR="${XYMONEXT_WORKDIR:-}"

if [ -z "$REAL" ]; then
    echo "$0: XYMONEXT_XYMON is not set - no client to send through" >&2
    exit 2
fi

# The message may arrive on stdin ("-" for standalone/xymon-send.sh,
# "@" for the xymon(1) binary). It has to be spooled to count it and
# still be able to feed it to the real client.
case "$2" in
    -|@)
        if [ -z "$WORKDIR" ] || [ ! -d "$WORKDIR" ]; then
            # Nothing to spool into: pass the stream through unmeasured
            # rather than losing the message.
            exec "$REAL" "$@"
        fi
        SPOOL="$WORKDIR/msg.$$"
        cat > "$SPOOL" || exit 1
        if [ -n "$COUNTFILE" ]; then
            SIZE=$(wc -c < "$SPOOL")
            # A short single write stays atomic even when several
            # messages are sent at the same time.
            printf '%s\n' "$SIZE" >> "$COUNTFILE"
        fi
        # exec: the shim leaves no process of its own behind, so the
        # measured extension is not charged for the instrumentation.
        exec "$REAL" "$1" "$2" < "$SPOOL"
        ;;
    *)
        if [ -n "$COUNTFILE" ]; then
            # ${#var} counts characters; extension messages are ASCII
            # (see CLAUDE.md), so that is the byte count. The trailing
            # newline the client appends is added here.
            MSG=$2
            printf '%s\n' "$(( ${#MSG} + 1 ))" >> "$COUNTFILE"
        fi
        exec "$REAL" "$@"
        ;;
esac
