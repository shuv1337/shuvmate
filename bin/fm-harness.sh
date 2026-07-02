#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh              print own harness: claude|codex|opencode|pi|unknown
#        fm-harness.sh crew         print the effective worker harness
#                                   (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate   print the effective secondmate supervisor harness
#                                   (config/secondmate-harness; "default" resolves to own)
#        fm-harness.sh crew-model   print the effective crew model token
#                                   (FM_CREW_MODEL env, else config/crew-model;
#                                   absent or "default" resolves to "opus")
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

detect_own() {
  # Layer 1: environment markers for verified harnesses.
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  [ "${PI_CODING_AGENT:-}" = "true" ] && { echo pi; return; }
  # Layer 2: walk the parent chain and match the command name.
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    case "$(basename "$comm")" in
      *claude*) echo claude; return ;;
      *codex*) echo codex; return ;;
      *opencode*) echo opencode; return ;;
      pi) echo pi; return ;;
      node*|python*)
        # Bare interpreter: match the harness name in its script path.
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$args" in
          *claude*) echo claude; return ;;
          *codex*) echo codex; return ;;
          *opencode*) echo opencode; return ;;
          *" pi "*|*/pi) echo pi; return ;;
        esac ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  echo unknown
}

resolve_configured_harness() {
  local file=$1 configured=
  [ -f "$CONFIG/$file" ] && configured=$(tr -d '[:space:]' < "$CONFIG/$file" || true)
  if [ -z "$configured" ] || [ "$configured" = "default" ]; then
    detect_own
  else
    echo "$configured"
  fi
}

# Resolve the effective crew model token for a claude launch.
# FM_CREW_MODEL (per-spawn override) wins over config/crew-model; absent or
# "default" resolves to the sensible baseline "opus" (capable for real coding
# and review work, far cheaper than the claude CLI's own Fable default).
resolve_crew_model() {
  local configured="${FM_CREW_MODEL:-}"
  if [ -z "$configured" ] && [ -f "$CONFIG/crew-model" ]; then
    configured=$(tr -d '[:space:]' < "$CONFIG/crew-model" || true)
  fi
  if [ -z "$configured" ] || [ "$configured" = "default" ]; then
    echo opus
  else
    echo "$configured"
  fi
}

case "${1:-}" in
  ''|own) detect_own ;;
  crew) resolve_configured_harness crew-harness ;;
  secondmate) resolve_configured_harness secondmate-harness ;;
  crew-model) resolve_crew_model ;;
  *)
    echo "usage: fm-harness.sh [own|crew|secondmate|crew-model]" >&2
    exit 2
    ;;
esac
