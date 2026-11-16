#!/usr/bin/env bash
# fleet.sh — discover and message the Claude Code instances running in Warp tabs.
#
# Discovery works because Warp tabs launch Claude Code as
#   claude --dangerously-skip-permissions /resume-log <Tab Name>
# so the tab name is in the process argv. Instances started without that
# argument fall back to their working directory's basename, to a name they
# claim with `fleet.sh claim`, or to $FLEET_NAME if it is exported.
#
# Delivery is pull-based: a message lands in the target's inbox and is surfaced
# to it by the fleet-inbox hook on its next turn. Treat it as email between
# agents, not as a function call.
#
# Claude Code also ships a native cross-session channel (ListAgents +
# SendMessage) that pushes directly into a live session. That is faster; use it
# first. This mailbox is the durable complement: a queued file survives a
# restart of either side, an enqueued message does not. See the README.
set -uo pipefail   # NOT -e: this script is mostly conditionals
FLEET="${FLEET_HOME:-$HOME/.claude/fleet}"
INBOX="$FLEET/inbox"; ARCHIVE="$FLEET/archive"; SHOWN="$FLEET/shown"
mkdir -p "$INBOX" "$ARCHIVE" "$SHOWN"

slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }
IDENT="$FLEET/identity"; mkdir -p "$IDENT"

# A Claude Code session is a process whose argv[0] basename is exactly `claude`.
is_claude() { local a0="${1%% *}"; [ "${a0##*/}" = claude ]; }

# Print: pid<TAB>uptime<TAB>cwd<TAB>tab name
roster() {
  local procs live=" "
  procs=$(ps -eo pid=,etime=,args= 2>/dev/null) || procs=""
  while read -r pid etime rest; do
    [ -n "${pid:-}" ] && is_claude "$rest" || continue
    live="$live$pid "
    name=$(echo "$rest" | sed -n 's/.*\/resume-log[[:space:]]*//p')
    if [ -z "$name" ] && [ -f "$IDENT/$pid" ]; then name=$(cat "$IDENT/$pid"); fi
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)
    if [ -z "$name" ]; then name="(unnamed: ${cwd##*/})"; fi
    printf '%s\t%s\t%s\t%s\n' "$pid" "$etime" "${cwd:-?}" "$name"
  done <<< "$procs"
  # Drop claims of pids that are no longer a live session, so a recycled pid
  # does not inherit a dead session's name. Skipped if ps returned nothing.
  [ -n "$procs" ] || return 0
  for f in "$IDENT"/*; do
    [ -f "$f" ] || continue
    case "$live" in *" ${f##*/} "*) ;; *) rm -f "$f" ;; esac
  done
}

# Which instance am I? Walk up the parent chain to the claude process.
whoami_tab() {
  # FLEET_NAME wins: for hosts with no tab name in argv (servers, cron, CI),
  # export FLEET_NAME=<stable name> and every send is stamped with it.
  if [ -n "${FLEET_NAME:-}" ]; then echo "$FLEET_NAME"; return 0; fi
  p=${PPID:-$$}
  for _ in 1 2 3 4 5 6; do
    args=$(ps -o args= -p "$p" 2>/dev/null || true)
    if is_claude "$args"; then
      n=$(echo "$args" | sed -n 's/.*\/resume-log[[:space:]]*//p')
      if [ -n "$n" ]; then echo "$n"; return 0; fi
      if [ -f "$IDENT/$p" ]; then cat "$IDENT/$p"; return 0; fi
      echo "(unnamed: ${PWD##*/})"; return 0
    fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
    if [ -z "$p" ] || [ "$p" = "1" ]; then break; fi
  done
  echo "(unnamed: ${PWD##*/})"
}

case "${1:-who}" in
  who)
    printf '%-8s %-12s %-34s %s\n' PID UPTIME CWD TAB
    roster | while IFS=$'\t' read -r pid etime cwd name; do
      n=$(find "$INBOX/$(slug "$name")" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
      if [ "${n:-0}" -gt 0 ]; then name="$name  [$n unread]"; fi
      printf '%-8s %-12s %-34s %s\n' "$pid" "$etime" "${cwd/#$HOME/\~}" "$name"
    done ;;

  whoami) whoami_tab ;;

  roster) roster ;;  # raw pid<TAB>uptime<TAB>cwd<TAB>name, used by broadcast.sh

  claim)
    [ $# -ge 2 ] || { echo "usage: fleet.sh claim <name>" >&2; exit 2; }
    p=${PPID:-$$}; found=""
    for _ in 1 2 3 4 5 6; do
      if is_claude "$(ps -o args= -p "$p" 2>/dev/null || true)"; then found=1; break; fi
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
      if [ -z "$p" ] || [ "$p" = "1" ]; then break; fi
    done
    [ -n "$found" ] || { echo "error: no claude process found above this shell; nothing claimed" >&2; exit 1; }
    echo "$2" > "$IDENT/$p"; echo "claimed pid $p as '$2'" ;;

  send)  # fleet.sh send "<tab name or slug>" "<message>"
    [ $# -ge 3 ] || { echo "usage: fleet.sh send <tab> <message>" >&2; exit 2; }
    target=$(slug "$2")
    [ -n "$target" ] || { echo "error: '$2' has no letters or digits to name a pane by" >&2; exit 2; }
    shift 2
    match=$(roster | cut -f4 | while read -r n; do [ "$(slug "$n")" = "$target" ] && echo "$n"; done | head -1)
    if [ -z "$match" ]; then echo "warning: no live tab matches '$target' (queuing anyway)" >&2; fi
    mkdir -p "$INBOX/$target"
    me=$(whoami_tab)
    # pid and $RANDOM keep two sends in one second apart; write to a dot-file
    # first and rename, so the hook never reads a half-written message.
    f="$INBOX/$target/$(date +%Y%m%dT%H%M%S)-$$$RANDOM-$(slug "$me").md"
    while [ -e "$f" ]; do f="${f%.md}x.md"; done
    tmp="$INBOX/$target/.${f##*/}.tmp"
    { echo "---"; echo "from: $me"; echo "at: $(date -Iseconds)"; echo "---"; echo; echo "$*"; } > "$tmp" && mv "$tmp" "$f"
    echo "queued -> $f" ;;

  inbox)  # unread for me (or a named tab)
    t=$(slug "${2:-$(whoami_tab)}")
    d="$INBOX/$t"; [ -d "$d" ] || { echo "(no messages for $t)"; exit 0; }
    : > "$SHOWN/$t.tmp"
    for f in "$d"/*.md; do
      [ -f "$f" ] || continue
      echo "=== ${f##*/} ==="; cat "$f"; echo; echo "${f##*/}" >> "$SHOWN/$t.tmp"
    done
    if [ -s "$SHOWN/$t.tmp" ]; then mv "$SHOWN/$t.tmp" "$SHOWN/$t"
    else rm -f "$SHOWN/$t.tmp"; echo "(no messages for $t)"; fi ;;

  ack)   # archive what the hook or `inbox` last displayed; mail that arrived since stays
    t=$(slug "${2:-$(whoami_tab)}")
    d="$INBOX/$t"; [ -d "$d" ] || exit 0
    mkdir -p "$ARCHIVE/$t"
    if [ -f "$SHOWN/$t" ]; then
      while IFS= read -r b; do
        case "$b" in ""|*/*) continue ;; esac
        if [ -f "$d/$b" ]; then mv "$d/$b" "$ARCHIVE/$t/"; fi
      done < "$SHOWN/$t"
      rm -f "$SHOWN/$t"
    else
      # Nothing recorded as shown (no hook installed): archive all mail, as before.
      for f in "$d"/*.md; do if [ -f "$f" ]; then mv "$f" "$ARCHIVE/$t/"; fi; done
    fi
    echo "acked $t" ;;

  *) echo "usage: fleet.sh {who|whoami|send <tab> <msg>|inbox [tab]|ack [tab]}" >&2; exit 2 ;;
esac
