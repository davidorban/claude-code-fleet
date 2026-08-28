#!/usr/bin/env bash
# broadcast.sh — send one message to every pane that has an inbox, except yourself.
#
# Cooperative by design. A pane reads the message on its next turn and decides what
# to do with it; nothing here can force another session to act. Use it for things
# that are safe for a pane to honour unilaterally, such as "stop your own poll loop"
# or "the shared checkout was reset, re-read your situation file".
#
# Usage:
#   broadcast.sh "your message"
#   broadcast.sh -f message.txt
set -uo pipefail

FLEET="${FLEET_HOME:-$HOME/.claude/fleet}"
CLI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fleet.sh"

if [ "${1:-}" = "-f" ]; then
  [ -n "${2:-}" ] && [ -r "$2" ] || { echo "usage: broadcast.sh -f <file>" >&2; exit 2; }
  MSG="$(cat "$2")"
else
  [ $# -ge 1 ] || { echo 'usage: broadcast.sh "<message>" | broadcast.sh -f <file>' >&2; exit 2; }
  MSG="$*"
fi

me="$("$CLI" whoami 2>/dev/null || echo unknown)"
me_slug=$(echo "$me" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')

sent=0
for d in "$FLEET/inbox"/*/; do
  [ -d "$d" ] || continue
  slug="$(basename "$d")"
  [ "$slug" = "$me_slug" ] && continue
  if "$CLI" send "$slug" "$MSG" >/dev/null 2>&1; then
    printf '  -> %s\n' "$slug"
    sent=$((sent + 1))
  fi
done

echo "queued to $sent pane(s), from '$me'."
