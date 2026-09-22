#!/bin/sh
#
# claude-expiry.sh -- privileged helper for the Xymon "claude" extension
#
# Prints when the Claude Code login of ONE account expires. It is the only
# part that needs root, and kept minimal on purpose: the argument is a
# user name, never a path (so the sudoers rule pins the accounts), and
# only timestamps and the subscription type are printed, never tokens.
#
# usage: claude-expiry.sh [-h|--help] USERNAME
#
# Program flow:
#   1. validate the argument (user name characters only)
#   2. look up the home directory (getent, else /etc/passwd)
#   3. extract expiresAt, refreshTokenExpiresAt, subscriptionType from
#      $HOME/.claude/.credentials.json
#   4. print key=value lines
#
# Output (exit 0 for every handled case, 2 on a usage error):
#   user=<name>
#   path=<credentials file>            (empty when the account is unknown)
#   status=ok|nofile|noread|nouser|badfile
#   expires=<epoch ms>, refreshexpires=<epoch ms>, subscription=<word>
#                                      (status=ok, where present)
#
# CLAUDE_PASSWD overrides /etc/passwd for the tests; sudo resets the
# environment, so it cannot be injected in production.

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
# Works for one-line and pretty-printed JSON: drop braces and blanks,
# split at commas, then match the anchored key (so "expiresAt" never
# matches "refreshTokenExpiresAt"). No jq on stock OpenWrt/FreeBSD.
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
