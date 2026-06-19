#!/usr/bin/env bash
# Print the tail of a crewmate pane (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <window-or-target> [lines=40]
#   <window-or-target> may be a bare task name (fm-xyz), session:window, or backend target.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUX="$FM_ROOT/bin/fm-mux.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

T=$("$MUX" resolve-task "$1")
N=${2:-40}
"$MUX" capture "$T" "$N"
