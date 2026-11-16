#!/bin/bash
# Fleet inbox watcher: when any pane has unread mail, ping David ONCE per change.
# Unread = a .md file sitting in ~/.claude/fleet/inbox/<pane>/ (ack moves it to archive/).
# Only notifies when the set of unread panes changes, so it doesn't nag on every tick.
FLEET="${FLEET_HOME:-$HOME/.claude/fleet}"
INBOX="$FLEET/inbox"
STATE="$FLEET/.inbox-watch-state"
LOG="$FLEET/.inbox-watch.log"

unread=()
for d in "$INBOX"/*/; do
  [ -d "$d" ] || continue
  pane="$(basename "$d")"
  n=$(find "$d" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && unread+=("$pane($n)")
done

sig=$(printf '%s\n' "${unread[@]}" | sort | shasum | awk '{print $1}')
prev=$(cat "$STATE" 2>/dev/null)
echo "$sig" > "$STATE"

if [ "${#unread[@]}" -gt 0 ] && [ "$sig" != "$prev" ]; then
  list="${unread[*]}"
  /usr/bin/osascript -e "display notification \"$list\" with title \"Fleet mail waiting — poke these panes\" sound name \"Ping\"" 2>>"$LOG"
  echo "$(date '+%Y-%m-%d %H:%M:%S')  notified: $list" >> "$LOG"
fi
