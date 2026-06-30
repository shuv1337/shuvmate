#!/usr/bin/env bash
# Multiplexer backend helper for firstmate supervision.
# Encapsulates tmux, zellij, and herdr command differences behind one surface.
#
# Verified zellij contract (0.45.0, 2026-06-18):
#   zellij attach --create-background <session>     detached session, CLI-drivable
#   zellij --session <s> action new-tab --name ... --cwd ...
#   zellij --session <s> action write-chars -p <pane> '<text>'   byte-faithful literal input
#   zellij --session <s> action send-keys -p <pane> "Enter"     submit (NOT write 10 / LF)
#   zellij --session <s> action send-keys -p <pane> "Esc"       interrupt
#   zellij --session <s> action dump-screen -p <pane>           viewport to STDOUT
#   zellij --session <s> action close-tab-by-id <tab-id>        scoped teardown
#
# Verified herdr contract (2026-06-30):
#   herdr pane current --current                                current pane metadata
#   herdr tab create --workspace <w> --cwd ... --label ...      tab + root pane
#   herdr tab list --workspace <w>                              tab metadata
#   herdr pane list [--workspace <w>]                           pane metadata
#   herdr pane send-text <pane> '<text>'                        byte-faithful literal input
#   herdr pane send-keys <pane> Enter                           submit
#   herdr pane read <pane> --source recent-unwrapped --lines N  bounded capture
#   herdr tab close <tab>                                       scoped teardown
#
# Usage:
#   fm-mux.sh current
#   fm-mux.sh configured
#   fm-mux.sh ensure-session <mux>
#   fm-mux.sh create <mux> <task-id> <cwd>
#   fm-mux.sh list [tmux|zellij|herdr|all]
#   fm-mux.sh resolve <target-or-name> [<mux>]
#   fm-mux.sh resolve-task <fm-name-or-target>
#   fm-mux.sh send-text <target> <text>
#   fm-mux.sh send-key <target> <key>
#   fm-mux.sh capture <target> <lines>
#   fm-mux.sh kill <target>
#   fm-mux.sh --help
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DEFAULT_SESSION=firstmate

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

die() { echo "error: $*" >&2; exit 1; }

read_mux_config() {
  local v=default
  if [ -f "$CONFIG/multiplexer" ]; then
    v=$(tr -d '[:space:]' < "$CONFIG/multiplexer" || true)
    [ -n "$v" ] || v=default
  fi
  printf '%s' "$v"
}

configured_mux() {
  case "$(read_mux_config)" in
    default|'') printf 'tmux' ;;
    tmux|zellij|herdr) printf '%s' "$(read_mux_config)" ;;
    *) die "unknown multiplexer in config/multiplexer: $(read_mux_config)" ;;
  esac
}

current_mux() {
  if [ -n "${HERDR_ENV:-}" ]; then
    printf 'herdr'
  elif [ -n "${ZELLIJ:-}" ]; then
    printf 'zellij'
  elif [ -n "${TMUX:-}" ]; then
    printf 'tmux'
  else
    printf 'none'
  fi
}

# Names of live (non-exited) zellij sessions, one per line. list-sessions marks
# dead sessions with "(EXITED ...)"; we never want to drive those, so filter
# them out and keep the first field (the session name).
zellij_live_sessions() {
  zellij list-sessions --no-formatting 2>/dev/null | grep -v 'EXITED' | awk 'NF { print $1 }'
}

zellij_session_exists() {
  zellij_live_sessions | grep -qxF "$1"
}

tmux_session_name() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    printf '%s' "$DEFAULT_SESSION"
  fi
}

# Resolve the live zellij session this firstmate is driving. ZELLIJ_SESSION_NAME
# is set by zellij at attach time but is NOT updated if the session is later
# renamed, so trusting it blindly makes every command target a session that no
# longer exists (empty fleet list; "attach to the current session" panic on
# spawn). Trust it only while it still names a live session; otherwise, if there
# is exactly one live session, that is the one we are in. Fall back to the
# default only when the situation is genuinely ambiguous.
zellij_session_name() {
  if [ -z "${ZELLIJ:-}" ]; then
    printf '%s' "$DEFAULT_SESSION"
    return
  fi
  local want="${ZELLIJ_SESSION_NAME:-}"
  if [ -n "$want" ] && zellij_session_exists "$want"; then
    printf '%s' "$want"
    return
  fi
  local live count
  live=$(zellij_live_sessions)
  count=$(printf '%s\n' "$live" | grep -c .)
  if [ "$count" -eq 1 ]; then
    printf '%s' "$live"
    return
  fi
  printf '%s' "${want:-$DEFAULT_SESSION}"
}

ensure_tmux_session() {
  local ses
  ses=$(tmux_session_name)
  if [ -z "${TMUX:-}" ]; then
    tmux has-session -t "$ses" 2>/dev/null || tmux new-session -d -s "$ses"
  fi
  printf '%s' "$ses"
}

ensure_zellij_session() {
  local ses _
  ses=$(zellij_session_name)
  if ! zellij_session_exists "$ses"; then
    zellij attach --create-background "$ses" >/dev/null
    # Wait for the session's initial pane to register before returning, so a
    # subsequent create's before/after pane diff isn't polluted by the default
    # pane appearing late and being mistaken for the new tab's pane.
    for _ in $(seq 1 25); do
      [ -n "$(zellij_list_pane_ids "$ses")" ] && break
      sleep 0.2
    done
  fi
  printf '%s' "$ses"
}

cmd_ensure_session() {
  local mux=$1 ses
  case "$mux" in
    tmux) ensure_tmux_session >/dev/null ;;
    zellij) ensure_zellij_session >/dev/null ;;
    herdr)
      command -v herdr >/dev/null || die "herdr not installed"
      [ -n "${HERDR_ENV:-}" ] || die "herdr selected in config/multiplexer but HERDR_ENV is not set; launch firstmate inside herdr"
      herdr pane current --current >/dev/null
      ;;
    *) die "unknown mux for ensure-session: $mux" ;;
  esac
}

zellij_tab_id_by_name() {
  local ses=$1 name=$2
  zellij --session "$ses" action list-tabs 2>/dev/null \
    | awk -v n="$name" 'NR > 1 && $3 == n { print $1; exit }'
}

zellij_list_pane_ids() {
  zellij --session "$1" action list-panes 2>/dev/null | awk 'NR > 1 { print $1 }'
}

# Live-scan fallback for tabs without stored meta. list-panes carries no tab
# linkage, but in zellij 0.45.0 a single-pane fm- tab's pane is terminal_<tab_id>.
# Validate the pane actually exists rather than blindly trusting that mapping;
# normal ops use the real pane id captured by cmd_create and stored in meta.
zellij_target_for_tab() {
  local ses=$1 tab_name=$2
  local tab_id pane
  tab_id=$(zellij_tab_id_by_name "$ses" "$tab_name") || true
  [ -n "$tab_id" ] || return 1
  pane="terminal_$tab_id"
  zellij_list_pane_ids "$ses" | grep -qxF "$pane" || return 1
  printf 'zellij:%s:%s:%s' "$ses" "$tab_id" "$pane"
}

json_get() {
  local expr=$1
  node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(0,"utf8")); const fn=new Function("data", "return " + process.argv[1]); const v=fn(data); if (v !== undefined && v !== null) console.log(String(v));' "$expr"
}

herdr_current_workspace() {
  herdr pane current --current | json_get 'data.result.pane.workspace_id'
}

herdr_tab_id_by_name() {
  local ws=$1 name=$2
  herdr tab list --workspace "$ws" | HERDR_TAB_NAME=$name json_get '(data.result.tabs || []).find(t => t.label === process.env.HERDR_TAB_NAME)?.tab_id'
}

herdr_root_pane_for_tab() {
  local ws=$1 tab=$2
  herdr pane list --workspace "$ws" | HERDR_TAB_ID=$tab json_get '(data.result.panes || []).find(p => p.tab_id === process.env.HERDR_TAB_ID)?.pane_id'
}

herdr_parse_target() {
  # herdr:<tab_id>/<pane_id>; ids themselves contain colons.
  local rest=${1#herdr:}
  HMUX_TAB=${rest%%/*}
  HMUX_PANE=${rest#*/}
  HMUX_WS=${HMUX_TAB%%:*}
}

herdr_target_for_tab() {
  local ws=$1 tab_name=$2 tab pane
  tab=$(herdr_tab_id_by_name "$ws" "$tab_name") || true
  [ -n "$tab" ] || return 1
  pane=$(herdr_root_pane_for_tab "$ws" "$tab") || true
  [ -n "$pane" ] || return 1
  printf 'herdr:%s/%s' "$tab" "$pane"
}

parse_target() {
  case "$1" in
    tmux:*|zellij:*|herdr:*) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

tmux_target_window() {
  printf '%s' "${1#tmux:}"
}

zellij_parse_target() {
  # zellij:session:tab_id:pane_id -> ZMUX_SES, ZMUX_TAB, ZMUX_PANE
  local rest=${1#zellij:}
  ZMUX_SES=${rest%%:*}
  rest=${rest#*:}
  ZMUX_TAB=${rest%%:*}
  ZMUX_PANE=${rest#*:}
}

cmd_create() {
  local mux=$1 id=$2 cwd=$3 ses name target before pane tab_id p ws
  name="fm-$id"
  case "$mux" in
    tmux)
      ses=$(ensure_tmux_session)
      if tmux list-windows -t "$ses" -F '#{window_name}' 2>/dev/null | grep -qxF "$name"; then
        die "window $ses:$name already exists"
      fi
      tmux new-window -d -t "$ses" -n "$name" -c "$cwd"
      target="tmux:$ses:$name"
      ;;
    zellij)
      command -v zellij >/dev/null || die "zellij not installed"
      ses=$(ensure_zellij_session)
      if [ -n "$(zellij_tab_id_by_name "$ses" "$name" || true)" ]; then
        die "tab $ses:$name already exists"
      fi
      # Capture the real pane id by diffing list-panes before/after the new tab.
      # Robust against any tab-id/pane-id coincidence and against splits.
      before=" $(zellij_list_pane_ids "$ses" | tr '\n' ' ') "
      zellij --session "$ses" action new-tab --name "$name" --cwd "$cwd" >/dev/null
      pane=""
      for _ in $(seq 1 25); do
        for p in $(zellij_list_pane_ids "$ses"); do
          case "$before" in
            *" $p "*) ;;
            *) pane=$p; break ;;
          esac
        done
        [ -n "$pane" ] && break
        sleep 0.2
      done
      [ -n "$pane" ] || die "could not find new pane for zellij tab $ses:$name"
      tab_id=$(zellij_tab_id_by_name "$ses" "$name")
      [ -n "$tab_id" ] || die "could not resolve tab id for $ses:$name after create"
      target="zellij:$ses:$tab_id:$pane"
      ;;
    herdr)
      command -v herdr >/dev/null || die "herdr not installed"
      [ -n "${HERDR_ENV:-}" ] || die "herdr selected in config/multiplexer but HERDR_ENV is not set"
      ws=$(herdr_current_workspace)
      [ -n "$ws" ] || die "could not resolve current herdr workspace"
      if [ -n "$(herdr_tab_id_by_name "$ws" "$name" || true)" ]; then
        die "tab $ws:$name already exists"
      fi
      target=$(herdr tab create --workspace "$ws" --cwd "$cwd" --label "$name" --no-focus \
        | json_get '"herdr:" + data.result.tab.tab_id + "/" + data.result.root_pane.pane_id')
      [ -n "$target" ] || die "could not create herdr tab for $name"
      ;;
    *) die "unknown mux for create: $mux" ;;
  esac
  printf '%s' "$target"
}

list_tmux_targets() {
  # Match the window field (always last), not a fm-* session name: the tmux:
  # prefix means a bare ':fm-' would also match sessions starting with fm-.
  tmux list-windows -a -F 'tmux:#{session_name}:#{window_name}' 2>/dev/null \
    | grep -E ':fm-[^:]*$' || true
}

list_zellij_sessions_to_scan() {
  if [ -n "${ZELLIJ:-}" ]; then
    printf '%s\n' "$(zellij_session_name)"
  fi
  if zellij_session_exists "$DEFAULT_SESSION"; then
    printf '%s\n' "$DEFAULT_SESSION"
  fi
}

list_zellij_targets() {
  local ses name target
  while IFS= read -r ses; do
    [ -n "$ses" ] || continue
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      target=$(zellij_target_for_tab "$ses" "$name" 2>/dev/null || true)
      [ -n "$target" ] || continue
      printf '%s\n' "$target"
    done < <(zellij --session "$ses" action list-tabs 2>/dev/null \
      | awk 'NR > 1 && $3 ~ /^fm-/ { print $3 }')
  done < <(list_zellij_sessions_to_scan | awk '!seen[$0]++')
}

list_herdr_targets() {
  local ws name target
  command -v herdr >/dev/null || return 0
  [ -n "${HERDR_ENV:-}" ] || return 0
  herdr workspace list 2>/dev/null | json_get '(data.result.workspaces || []).map(w => w.workspace_id).join("\n")' \
    | while IFS= read -r ws; do
      [ -n "$ws" ] || continue
      herdr tab list --workspace "$ws" 2>/dev/null \
        | json_get '(data.result.tabs || []).filter(t => /^fm-/.test(t.label || "")).map(t => t.label).join("\n")' \
        | while IFS= read -r name; do
          [ -n "$name" ] || continue
          target=$(herdr_target_for_tab "$ws" "$name" 2>/dev/null || true)
          [ -n "$target" ] && printf '%s\n' "$target"
        done
    done
}

cmd_list() {
  local scope=${1:-all}
  case "$scope" in
    tmux) list_tmux_targets ;;
    zellij) list_zellij_targets ;;
    herdr) list_herdr_targets ;;
    all)
      {
        list_tmux_targets
        list_zellij_targets
        list_herdr_targets
      } | awk '!seen[$0]++'
      ;;
    *) die "unknown list scope: $scope (expected tmux|zellij|herdr|all)" ;;
  esac
}

resolve_tmux_name() {
  local name=$1
  tmux list-windows -a -F 'tmux:#{session_name}:#{window_name}' 2>/dev/null \
    | grep -m1 ":$name\$" \
    || die "no tmux window named $name"
}

resolve_zellij_name() {
  local name=$1 ses target
  while IFS= read -r ses; do
    [ -n "$ses" ] || continue
    target=$(zellij_target_for_tab "$ses" "$name" 2>/dev/null || true)
    if [ -n "$target" ]; then
      printf '%s' "$target"
      return 0
    fi
  done < <(list_zellij_sessions_to_scan | awk '!seen[$0]++')
  die "no zellij tab named $name"
}

resolve_herdr_name() {
  local name=$1 ws target
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    target=$(herdr_target_for_tab "$ws" "$name" 2>/dev/null || true)
    if [ -n "$target" ]; then
      printf '%s' "$target"
      return 0
    fi
  done < <(herdr workspace list 2>/dev/null | json_get '(data.result.workspaces || []).map(w => w.workspace_id).join("\n")')
  die "no herdr tab named $name"
}

cmd_resolve() {
  local arg=${1:-} mux=${2:-}
  [ -n "$arg" ] || die "resolve requires a target or name"
  if parse_target "$arg" >/dev/null 2>&1; then
    printf '%s' "$arg"
    return 0
  fi
  case "$arg" in
    *:*) die "unrecognized target: $arg" ;;
  esac
  case "$mux" in
    ''|all)
      if target=$(resolve_tmux_name "$arg" 2>/dev/null); then
        printf '%s' "$target"
        return 0
      fi
      if target=$(resolve_zellij_name "$arg" 2>/dev/null); then
        printf '%s' "$target"
        return 0
      fi
      if target=$(resolve_herdr_name "$arg" 2>/dev/null); then
        printf '%s' "$target"
        return 0
      fi
      die "no task surface named $arg"
      ;;
    tmux) resolve_tmux_name "$arg" ;;
    zellij) resolve_zellij_name "$arg" ;;
    herdr) resolve_herdr_name "$arg" ;;
    *) die "unknown mux for resolve: $mux" ;;
  esac
}

task_id_from_name() {
  case "$1" in
    fm-*) printf '%s' "${1#fm-}" ;;
    *) printf '%s' "$1" ;;
  esac
}

meta_field() {
  local file=$1 key=$2
  grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- || true
}

cmd_resolve_task() {
  local arg=${1:-} id meta mux target window
  [ -n "$arg" ] || die "resolve-task requires a name or target"
  if parse_target "$arg" >/dev/null 2>&1; then
    printf '%s' "$arg"
    return 0
  fi
  # An explicit session:window (the escape hatch for surfaces outside this home's
  # meta) is treated as a bare tmux target. Backend-prefixed targets were already
  # handled by parse_target above.
  case "$arg" in
    *:*) printf 'tmux:%s' "$arg"; return 0 ;;
  esac
  id=$(task_id_from_name "$arg")
  meta="$STATE/$id.meta"
  # A bare `fm-<id>` is resolved ONLY through this home's meta: home isolation
  # means we must NOT fall back to a global multiplexer listing that could match a
  # foreign same-named surface in another firstmate home. Refuse instead, with the
  # escape-hatch hint to pass an explicit session:window for a surface outside this
  # home (the same contract the tmux-only resolver enforced).
  case "$arg" in
    fm-*)
      [ -f "$meta" ] || die "no metadata for $arg in $STATE; pass session:window to target a window outside this firstmate home"
      mux=$(meta_field "$meta" mux)
      target=$(meta_field "$meta" target)
      window=$(meta_field "$meta" window)
      [ -n "$mux" ] || mux=tmux
      if [ -z "$target" ] && [ -n "$window" ]; then
        target="tmux:$window"
      fi
      [ -n "$target" ] || die "no window recorded in $meta"
      printf '%s' "$target"
      return 0
      ;;
  esac
  # A non-fm-* bare name: resolve by scanning live surfaces (used by interactive
  # peeks of arbitrary windows). This was never home-scoped.
  if [ -f "$meta" ]; then
    mux=$(meta_field "$meta" mux)
    target=$(meta_field "$meta" target)
    window=$(meta_field "$meta" window)
    [ -n "$mux" ] || mux=tmux
    if [ -z "$target" ] && [ -n "$window" ]; then
      target="tmux:$window"
    fi
    [ -n "$target" ] || die "meta for $id has no target or window"
    printf '%s' "$target"
    return 0
  fi
  cmd_resolve "$arg"
}

map_key_for_zellij() {
  case "$1" in
    Escape|Esc) printf 'Esc' ;;
    Enter) printf 'Enter' ;;
    C-c) printf 'Ctrl c' ;;
    *) printf '%s' "$1" ;;
  esac
}

send_herdr_key() {
  local pane=$1 key=$2
  case "$key" in
    Escape|Esc) herdr pane send-keys "$pane" Esc >/dev/null ;;
    Enter) herdr pane send-keys "$pane" Enter >/dev/null ;;
    C-c) herdr pane send-keys "$pane" Ctrl c >/dev/null ;;
    *) herdr pane send-keys "$pane" "$key" >/dev/null ;;
  esac
}

cmd_send_text() {
  local target=$1
  shift
  [ $# -gt 0 ] || die "send-text requires text"
  local text=$* win
  case "$target" in
    tmux:*)
      win=$(tmux_target_window "$target")
      tmux send-keys -t "$win" -l "$text"
      ;;
    zellij:*)
      zellij_parse_target "$target"
      zellij --session "$ZMUX_SES" action write-chars -p "$ZMUX_PANE" "$text"
      ;;
    herdr:*)
      herdr_parse_target "$target"
      herdr pane send-text "$HMUX_PANE" "$text" >/dev/null
      ;;
    *) die "invalid target for send-text: $target" ;;
  esac
}

cmd_send_key() {
  local target=$1 key=$2 win zkey
  [ -n "$key" ] || die "send-key requires a key name"
  case "$target" in
    tmux:*)
      win=$(tmux_target_window "$target")
      tmux send-keys -t "$win" "$key"
      ;;
    zellij:*)
      zellij_parse_target "$target"
      zkey=$(map_key_for_zellij "$key")
      zellij --session "$ZMUX_SES" action send-keys -p "$ZMUX_PANE" "$zkey"
      ;;
    herdr:*)
      herdr_parse_target "$target"
      send_herdr_key "$HMUX_PANE" "$key"
      ;;
    *) die "invalid target for send-key: $target" ;;
  esac
}

cmd_capture() {
  local target=$1 lines=${2:-40} win out
  case "$target" in
    tmux:*)
      win=$(tmux_target_window "$target")
      # tmux reports dead targets via capture-pane's exit status.
      tmux capture-pane -p -t "$win" -S -"$lines" 2>/dev/null
      ;;
    zellij:*)
      zellij_parse_target "$target"
      # zellij dump-screen exits 0 with empty output for dead pane ids, so
      # validate liveness through the authoritative pane list first.
      zellij_list_pane_ids "$ZMUX_SES" | grep -qxF "$ZMUX_PANE" || return 1
      out=$(zellij --session "$ZMUX_SES" action dump-screen -p "$ZMUX_PANE" 2>/dev/null) || return 1
      printf '%s\n' "$out" | tail -n "$lines"
      ;;
    herdr:*)
      herdr_parse_target "$target"
      herdr pane get "$HMUX_PANE" >/dev/null || return 1
      herdr pane read "$HMUX_PANE" --source recent-unwrapped --lines "$lines" --format text 2>/dev/null
      ;;
    *) die "invalid target for capture: $target" ;;
  esac
}

cmd_kill() {
  local target=$1 win
  case "$target" in
    tmux:*)
      win=$(tmux_target_window "$target")
      tmux kill-window -t "$win" 2>/dev/null || true
      ;;
    zellij:*)
      zellij_parse_target "$target"
      zellij --session "$ZMUX_SES" action close-tab-by-id "$ZMUX_TAB" 2>/dev/null || true
      ;;
    herdr:*)
      herdr_parse_target "$target"
      herdr tab close "$HMUX_TAB" >/dev/null 2>&1 || true
      ;;
    *) die "invalid target for kill: $target" ;;
  esac
}

main() {
  local cmd=${1:-}
  case "$cmd" in
    -h|--help|help|'') usage 0 ;;
    current) current_mux ;;
    configured) configured_mux ;;
    ensure-session)
      [ $# -ge 2 ] || die "usage: fm-mux.sh ensure-session <mux>"
      cmd_ensure_session "$2"
      ;;
    create)
      [ $# -ge 4 ] || die "usage: fm-mux.sh create <mux> <task-id> <cwd>"
      cmd_create "$2" "$3" "$4"
      ;;
    list)
      cmd_list "${2:-all}"
      ;;
    resolve)
      [ $# -ge 2 ] || die "usage: fm-mux.sh resolve <target-or-name> [<mux>]"
      cmd_resolve "$2" "${3:-}"
      ;;
    resolve-task)
      [ $# -ge 2 ] || die "usage: fm-mux.sh resolve-task <fm-name-or-target>"
      cmd_resolve_task "$2"
      ;;
    send-text)
      [ $# -ge 3 ] || die "usage: fm-mux.sh send-text <target> <text>"
      cmd_send_text "$2" "${@:3}"
      ;;
    send-key)
      [ $# -ge 3 ] || die "usage: fm-mux.sh send-key <target> <key>"
      cmd_send_key "$2" "$3"
      ;;
    capture)
      [ $# -ge 2 ] || die "usage: fm-mux.sh capture <target> [lines]"
      cmd_capture "$2" "${3:-40}"
      ;;
    kill)
      [ $# -ge 2 ] || die "usage: fm-mux.sh kill <target>"
      cmd_kill "$2"
      ;;
    *)
      die "unknown subcommand: $cmd (try --help)"
      ;;
  esac
}

main "$@"
