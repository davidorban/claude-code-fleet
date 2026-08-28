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
FLEET="$HOME/.claude/fleet"
INBOX="$FLEET/inbox"; ARCHIVE="$FLEET/archive"
mkdir -p "$INBOX" "$ARCHIVE"

slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }
IDENT="$HOME/.claude/fleet/identity"; mkdir -p "$IDENT"

# Print: pid<TAB>uptime<TAB>cwd<TAB>tab name
roster() {
  ps -eo pid=,etime=,args= | grep -E '[c]laude( |$)' | grep -v 'fleet.sh' | while read -r pid etime rest; do
    case "$rest" in *"/bin/zsh"*|*"bun run"*) continue ;; esac
    name=$(echo "$rest" | sed -n 's/.*\/resume-log[[:space:]]*//p')
    if [ -z "$name" ] && [ -f "$IDENT/$pid" ]; then name=$(cat "$IDENT/$pid"); fi
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)
    if [ -z "$name" ]; then name="(unnamed: ${cwd##*/})"; fi
    printf '%s\t%s\t%s\t%s\n' "$pid" "$etime" "${cwd:-?}" "$name"
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
    case "$args" in
      claude*)
        n=$(echo "$args" | sed -n 's/.*\/resume-log[[:space:]]*//p')
        if [ -n "$n" ]; then echo "$n"; return 0; fi
        if [ -f "$IDENT/$p" ]; then cat "$IDENT/$p"; return 0; fi
        echo "(unnamed: ${PWD##*/})"; return 0 ;;
    esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
    if [ -z "$p" ] || [ "$p" = "1" ]; then break; fi
  done
  echo "(unnamed: ${PWD##*/})"
}

case "${1:-who}" in
  who)
    printf '%-8s %-12s %-34s %s\n' PID UPTIME CWD TAB
    roster | while IFS=$'\t' read -r pid etime cwd name; do
      n=$(ls "$INBOX/$(slug "$name")" 2>/dev/null | wc -l | tr -d ' ')
      if [ "${n:-0}" -gt 0 ]; then name="$name  [$n unread]"; fi
      printf '%-8s %-12s %-34s %s\n' "$pid" "$etime" "${cwd/#$HOME/\~}" "$name"
    done ;;

  whoami) whoami_tab ;;

  claim)
    [ $# -ge 2 ] || { echo "usage: fleet.sh claim <name>" >&2; exit 2; }
    p=${PPID:-$$}
    for _ in 1 2 3 4 5 6; do
      case "$(ps -o args= -p "$p" 2>/dev/null || true)" in claude*) break ;; esac
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
      if [ -z "$p" ] || [ "$p" = "1" ]; then break; fi
    done
    echo "$2" > "$IDENT/$p"; echo "claimed pid $p as '$2'" ;;

  send)  # fleet.sh send "<tab name or slug>" "<message>"
    [ $# -ge 3 ] || { echo "usage: fleet.sh send <tab> <message>" >&2; exit 2; }
    target=$(slug "$2"); shift 2
    match=$(roster | cut -f4 | while read -r n; do [ "$(slug "$n")" = "$target" ] && echo "$n"; done | head -1)
    if [ -z "$match" ]; then echo "warning: no live tab matches '$target' (queuing anyway)" >&2; fi
    mkdir -p "$INBOX/$target"
    f="$INBOX/$target/$(date +%Y%m%dT%H%M%S)-$(slug "$(whoami_tab)").md"
    { echo "---"; echo "from: $(whoami_tab)"; echo "at: $(date -Iseconds)"; echo "---"; echo; echo "$*"; } > "$f"
    echo "queued -> $f" ;;

  inbox)  # unread for me (or a named tab)
    t=$(slug "${2:-$(whoami_tab)}")
    d="$INBOX/$t"; [ -d "$d" ] || { echo "(no messages for $t)"; exit 0; }
    n=$(ls "$d" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" = "0" ]; then echo "(no messages for $t)"; exit 0; fi
    for f in "$d"/*; do echo "=== ${f##*/} ==="; cat "$f"; echo; done ;;

  ack)   # archive everything I've read
    t=$(slug "${2:-$(whoami_tab)}")
    d="$INBOX/$t"; [ -d "$d" ] || exit 0
    mkdir -p "$ARCHIVE/$t"
    mv "$d"/* "$ARCHIVE/$t/" 2>/dev/null || true
    echo "acked $t" ;;

  *) echo "usage: fleet.sh {who|whoami|send <tab> <msg>|inbox [tab]|ack [tab]}" >&2; exit 2 ;;
esac
