#!/usr/bin/env bash
# fleet-remote.sh — deliver a message into the fleet inbox on ANOTHER host, over ssh.
#
# For the case where the sessions you want to talk to are on your workstation but the
# thing with something to say is a server: a cron job, a scheduled agent run, a CI step.
# The mailbox is a directory of files, so delivery is just writing a file over ssh.
#
# Requires: key-based ssh to <host>, and ~/.claude/fleet/inbox existing there.
#
# Usage:
#   FLEET_NAME=build-server fleet-remote.sh <ssh-host> "<pane>" "<message>"
#   FLEET_NAME=build-server fleet-remote.sh <ssh-host> "<pane>" -f message.txt
#
# Example:
#   FLEET_NAME=dex-ops fleet-remote.sh mac "Notes" "nightly job failed, see /var/log/x"
set -euo pipefail

HOST="${1:-}"; PANE="${2:-}"; shift 2 || true
[ -n "$HOST" ] && [ -n "$PANE" ] || {
  echo 'usage: fleet-remote.sh <ssh-host> "<pane>" "<message>"' >&2; exit 2; }

if [ "${1:-}" = "-f" ]; then
  [ -n "${2:-}" ] && [ -r "$2" ] || { echo "usage: ... -f <file>" >&2; exit 2; }
  MSG="$(cat "$2")"
else
  [ $# -ge 1 ] || { echo "no message given" >&2; exit 2; }
  MSG="$*"
fi

slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }

FROM="${FLEET_NAME:-$(hostname -s)}"
TARGET="$(slug "$PANE")"
STAMP="$(date +%Y%m%dT%H%M%S)"
REMOTE_DIR="\$HOME/.claude/fleet/inbox/$TARGET"
REMOTE_FILE="$REMOTE_DIR/$STAMP-$(slug "$FROM").md"

{
  echo "---"
  echo "from: $FROM"
  echo "at: $(date -Iseconds)"
  echo "via: fleet-remote over ssh"
  echo "---"
  echo
  echo "$MSG"
} | ssh "$HOST" "mkdir -p $REMOTE_DIR && cat > $REMOTE_FILE && echo delivered: $REMOTE_FILE"
