#!/usr/bin/env bash
# Maintain data/captain-asks.md, the local operator-facing ledger of work that
# is waiting on the captain: decisions, blockers, credentials, review/merge
# approvals, and other captain-owned actions.
# Usage:
#   fm-captain-asks.sh path
#   fm-captain-asks.sh list
#   fm-captain-asks.sh add <task-id> <type> <summary> [--source <text>]
#   fm-captain-asks.sh resolve <task-id> [type] [--note <text>]
#   fm-captain-asks.sh sync-from-state
# Every mutating verb also regenerates the HTML operator view via
# fm-asks-html.sh, best-effort: a render failure never fails the mutation.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ASKS="$DATA/captain-asks.md"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

today() { date +%Y-%m-%d; }

# Best-effort HTML view refresh after a mutation; never fails the verb and
# never adds to its stdout, so the CLI contract stays byte-identical.
render_view() {
  "$SCRIPT_DIR/fm-asks-html.sh" >/dev/null 2>&1 || true
}

sanitize_key_part() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

digest_text() {
  printf '%s' "$1" | cksum | awk '{print $1}'
}

ensure_file() {
  mkdir -p "$DATA"
  if [ ! -f "$ASKS" ]; then
    cat > "$ASKS" <<'EOF'
# Captain asks

Open decisions, blockers, credentials, review or merge approvals, and any other captain-owned action.

## Open

## Resolved
EOF
    return
  fi
  grep -qxF '## Open' "$ASKS" || printf '\n## Open\n' >> "$ASKS"
  grep -qxF '## Resolved' "$ASKS" || printf '\n## Resolved\n' >> "$ASKS"
}

ask_key() {
  local id=$1 type=$2 summary=$3
  printf '%s:%s:%s' "$(sanitize_key_part "$id")" "$(sanitize_key_part "$type")" "$(digest_text "$summary")"
}

insert_open_line() {
  local line=$1 tmp
  tmp=$(mktemp "$DATA/.captain-asks.XXXXXX")
  awk -v line="$line" '
    /^## Open$/ && !done {
      print
      print ""
      print line
      done = 1
      skip_blank = 1
      next
    }
    skip_blank && /^$/ {
      skip_blank = 0
      next
    }
    { skip_blank = 0; print }
  ' "$ASKS" > "$tmp"
  mv "$tmp" "$ASKS"
}

cmd_add() {
  [ $# -ge 3 ] || { echo "usage: fm-captain-asks.sh add <task-id> <type> <summary> [--source <text>]" >&2; exit 1; }
  local id=$1 type=$2 summary=$3 source="" key line
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) shift; source=${1:-}; [ $# -gt 0 ] || { echo "error: --source needs a value" >&2; exit 1; } ;;
      *) echo "error: unknown option: $1" >&2; exit 1 ;;
    esac
    shift
  done

  ensure_file
  key=$(ask_key "$id" "$type" "$summary")
  if grep -F "<!-- fm-ask:$key -->" "$ASKS" >/dev/null 2>&1; then
    echo "already tracked: $id $type"
    return 0
  fi
  line="- [ ] $(today) | $id | $type | $summary"
  [ -n "$source" ] && line="$line | source: $source"
  line="$line <!-- fm-ask:$key -->"
  insert_open_line "$line"
  echo "tracked: $id $type"
}

cmd_resolve() {
  [ $# -ge 1 ] || { echo "usage: fm-captain-asks.sh resolve <task-id> [type] [--note <text>]" >&2; exit 1; }
  local id=$1 type="" note="" safe_id safe_type tmp moved rc
  shift
  if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then
    type=$1
    shift
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --note) shift; note=${1:-}; [ $# -gt 0 ] || { echo "error: --note needs a value" >&2; exit 1; } ;;
      *) echo "error: unknown option: $1" >&2; exit 1 ;;
    esac
    shift
  done

  ensure_file
  safe_id=$(sanitize_key_part "$id")
  safe_type=$(sanitize_key_part "$type")
  tmp=$(mktemp "$DATA/.captain-asks.XXXXXX")
  moved=$(mktemp "$DATA/.captain-asks-moved.XXXXXX")
  set +e
  awk -v safe_id="$safe_id" -v safe_type="$safe_type" -v date="$(today)" -v note="$note" -v moved="$moved" '
    /^## Open$/ { in_open = 1; print; next }
    /^## Resolved$/ {
      in_open = 0
      print
      close(moved)
      while ((getline line < moved) > 0) print line
      next
    }
    in_open && index($0, "<!-- fm-ask:" safe_id ":") {
      if (safe_type != "" && !index($0, "<!-- fm-ask:" safe_id ":" safe_type ":")) {
        print
        next
      }
      line = $0
      comment = " <!-- fm-ask:"
      pos = index(line, comment)
      prefix = substr(line, 1, pos - 1)
      suffix = substr(line, pos)
      sub(/^- \[ \]/, "- [x]", prefix)
      resolved = " (resolved " date
      if (note != "") resolved = resolved ": " note
      resolved = resolved ")"
      print prefix resolved suffix >> moved
      count++
      next
    }
    { print }
    END { if (count == 0) exit 2 }
  ' "$ASKS" > "$tmp"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then
    rm -f "$tmp" "$moved"
    echo "no open asks matched: $id${type:+ $type}"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp" "$moved"
    echo "error: failed to update $ASKS" >&2
    exit "$rc"
  fi
  mv "$tmp" "$ASKS"
  rm -f "$moved"
  echo "resolved: $id${type:+ $type}"
}

status_to_ask_type() {
  local line=$1
  case "$line" in
    needs-decision:*) echo decision ;;
    blocked:*) echo blocker ;;
    failed:*) echo failure ;;
    *ready\ in\ branch*) echo local-merge ;;
    *PR*|*checks\ green*|*PR\ ready*) echo merge ;;
    *) return 1 ;;
  esac
}

cmd_sync_from_state() {
  ensure_file
  local f task last type
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" || continue
    type=$(status_to_ask_type "$last") || continue
    task=$(basename "$f")
    task="${task%.status}"
    cmd_add "$task" "$type" "$last" --source "status:$(basename "$f")" >/dev/null
  done
  echo "synced: $ASKS"
}

case "${1:-}" in
  path) ensure_file; printf '%s\n' "$ASKS" ;;
  list|"") ensure_file; cat "$ASKS" ;;
  add) shift; cmd_add "$@"; render_view ;;
  resolve) shift; cmd_resolve "$@"; render_view ;;
  sync-from-state) cmd_sync_from_state; render_view ;;
  *)
    echo "usage: fm-captain-asks.sh path|list|add|resolve|sync-from-state" >&2
    exit 1
    ;;
esac
