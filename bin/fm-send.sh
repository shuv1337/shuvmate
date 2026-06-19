#!/usr/bin/env bash
# Send one line of literal text to a crewmate task surface, then Enter.
# Usage: fm-send.sh <window-or-target> <text...>
#   <window-or-target> may be a bare task name (fm-xyz), session:window, or backend target.
# Special keys instead of text: fm-send.sh <window-or-target> --key Escape   (or Enter, C-c, ...)
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUX="$FM_ROOT/bin/fm-mux.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

T=$("$MUX" resolve-task "$1")
shift

if [ "${1:-}" = "--key" ]; then
  "$MUX" send-key "$T" "$2"
else
  TEXT=$*
  "$MUX" send-text "$T" "$TEXT"
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing. Give popups time to settle.
  case "$TEXT" in /*) sleep 1.2 ;; *) sleep 0.3 ;; esac
  "$MUX" send-key "$T" Enter
fi
