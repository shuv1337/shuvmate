#!/usr/bin/env bash
# Print the tail of a crewmate pane (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <window-or-target> [lines=40]
#   <window-or-target> may be a bare task name (fm-xyz), resolved through this
#   home's state/<id>.meta (mux= and target=), an explicit session:window, or a
#   backend target. Resolution and capture go through fm-mux.sh so both tmux
#   windows and zellij tabs are handled.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
MUX="$SCRIPT_DIR/fm-mux.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

T=$("$MUX" resolve-task "$1")
N=${2:-40}
"$MUX" capture "$T" "$N"
