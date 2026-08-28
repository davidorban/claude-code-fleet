#!/usr/bin/env bash
# install.sh — copy the fleet scripts into ~/.claude/fleet and put fleet.sh on PATH.
# Does not edit settings.json; it prints the hook block for you to paste.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${FLEET_HOME:-$HOME/.claude/fleet}"
BINDIR="$HOME/.local/bin"

mkdir -p "$DEST" "$DEST/inbox" "$DEST/archive" "$DEST/identity" "$BINDIR"

install -m 0755 "$SRC/bin/fleet.sh"            "$DEST/fleet.sh"
install -m 0755 "$SRC/bin/broadcast.sh"        "$DEST/broadcast.sh"
install -m 0755 "$SRC/bin/inbox-watch.sh"      "$DEST/inbox-watch.sh"
install -m 0755 "$SRC/hooks/fleet-inbox-hook.sh" "$DEST/fleet-inbox-hook.sh"

ln -sf "$DEST/fleet.sh"     "$BINDIR/fleet.sh"
ln -sf "$DEST/broadcast.sh" "$BINDIR/broadcast.sh"

echo "installed to $DEST"
echo "symlinked fleet.sh and broadcast.sh into $BINDIR"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo; echo "NOTE: $BINDIR is not on your PATH. Add it, or call $DEST/fleet.sh by full path." ;;
esac

cat <<'EOF'

Add this to ~/.claude/settings.json so messages surface in every session:

  {
    "hooks": {
      "UserPromptSubmit": [
        { "hooks": [ { "type": "command",
                       "command": "$HOME/.claude/fleet/fleet-inbox-hook.sh" } ] }
      ]
    }
  }

If you already have a UserPromptSubmit array, append to it rather than replacing it.

Then, in each session:  fleet.sh claim "<a name>"
And to check the roster: fleet.sh who
EOF
