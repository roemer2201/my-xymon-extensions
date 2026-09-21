#!/bin/sh
#
# claude-expiry.sh -- privileged helper for the Xymon "claude" extension
#
# Prints when the Claude Code login of ONE account expires. Claude Code
# keeps its OAuth tokens in $HOME/.claude/.credentials.json with mode
# 0600, so the Xymon client - which runs as an unprivileged user - can
# not read the file of another account. This helper is the only part
# that needs root, and it is deliberately kept small and dumb:
#
#   - It takes exactly one argument, a USER NAME, never a path. The
#     sudoers rule can therefore pin down which accounts may be asked
#     about, and no file outside those accounts can be reached through
#     the argument.
#   - It prints the two expiry timestamps and the subscription type,
#     and nothing else. Token material never leaves this script, not
#     even truncated.
#
# usage: claude-expiry.sh [-h|--help] USERNAME
#
# Program flow:
#   1. parse and validate the argument (user name characters only)
#   2. look up the account's home directory (getent, else /etc/passwd)
#   3. locate $HOME/.claude/.credentials.json
#   4. extract expiresAt, refreshTokenExpiresAt and subscriptionType
#   5. print them as key=value lines, with status= saying what happened
#
# Output (exit code 0 for every handled case, 2 on a usage error):
#   user=<name>
#   path=<credentials file>            (empty when the account is unknown)
#   status=ok|nofile|noread|nouser|badfile
#   expires=<epoch milliseconds>       (status=ok)
#   refreshexpires=<epoch milliseconds>(status=ok)
#   subscription=<word>                (status=ok, when the field exists)
#
# CLAUDE_PASSWD overrides /etc/passwd; the test suite uses it. sudo
# resets the environment, so it cannot be injected through the sudo
# call the extension makes.

set -u

LC_ALL=C
export LC_ALL

usage() {
    cat <<'EOF'
usage: claude-expiry.sh [-h|--help] USERNAME

Prints when the Claude Code login of USERNAME expires, as key=value
lines (status, path, expires, refreshexpires, subscription). Tokens are
never printed. Meant to be called by the Xymon "claude" extension,
through sudo where the Xymon client does not run as root - see
sudoers.example.
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

if [ $# -ne 1 ]; then
    usage >&2
    exit 2
fi

USERNAME=$1

# Accept nothing but a plain account name. Everything a path needs -
# slashes, dots leading the name, whitespace - is rejected here.
case "$USERNAME" in
    ''|-*|.*|*[!A-Za-z0-9._-]*)
        echo "claude-expiry.sh: not a valid user name" >&2
        exit 2
        ;;
esac

CLAUDE_PASSWD="${CLAUDE_PASSWD:-}"

lookup_home() { # lookup_home <user> -> home directory, empty if unknown
    if [ -n "$CLAUDE_PASSWD" ]; then
        awk -F: -v u="$1" '$1 == u { print $6; exit }' "$CLAUDE_PASSWD"
    elif command -v getent >/dev/null 2>&1; then
        getent passwd "$1" 2>/dev/null | awk -F: '{ print $6; exit }'
    else
        awk -F: -v u="$1" '$1 == u { print $6; exit }' /etc/passwd
    fi
}

# json_field <key> <file> <value-pattern>
#
# The credentials file is JSON written by Claude Code, either on one
# line or pretty printed. Braces and blanks are dropped and commas
# turned into newlines, which leaves one "key":value per line in both
# cases; the anchored expression then picks the wanted key only (so
# "expiresAt" never matches "refreshTokenExpiresAt"). No jq: it does
# not exist on a stock OpenWrt or FreeBSD host.
json_field() {
    tr -d '{} \t\r' < "$2" | tr ',' '\n' \
        | sed -n "s/^\"$1\":\($3\)\$/\1/p" | head -1
}

HOMEDIR=$(lookup_home "$USERNAME")
if [ -z "$HOMEDIR" ]; then
    printf 'user=%s\npath=\nstatus=nouser\n' "$USERNAME"
    exit 0
fi

CREDS="$HOMEDIR/.claude/.credentials.json"

printf 'user=%s\npath=%s\n' "$USERNAME" "$CREDS"

if [ ! -f "$CREDS" ]; then
    echo "status=nofile"
    exit 0
fi
if [ ! -r "$CREDS" ]; then
    echo "status=noread"
    exit 0
fi

REFRESH=$(json_field refreshTokenExpiresAt "$CREDS" '[0-9][0-9]*')
ACCESS=$(json_field expiresAt "$CREDS" '[0-9][0-9]*')
SUBSCRIPTION=$(json_field subscriptionType "$CREDS" '"[A-Za-z0-9_.-]*"' | tr -d '"')

if [ -z "$REFRESH" ]; then
    # The file exists but carries no refresh token expiry: either a
    # login that was never completed, a format change, or a truncated
    # file caught mid-rewrite. The extension reports that as yellow.
    echo "status=badfile"
    exit 0
fi

echo "status=ok"
printf 'refreshexpires=%s\n' "$REFRESH"
[ -n "$ACCESS" ] && printf 'expires=%s\n' "$ACCESS"
[ -n "$SUBSCRIPTION" ] && printf 'subscription=%s\n' "$SUBSCRIPTION"

exit 0
