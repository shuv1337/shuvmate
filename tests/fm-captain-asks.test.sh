#!/usr/bin/env bash
# Tests for data/captain-asks.md maintenance.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASKS="$ROOT/bin/fm-captain-asks.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-asks-tests)

run_asks() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$ASKS" "$@"
}

test_add_is_idempotent_and_resolve_moves_to_resolved() {
  local case_dir file
  case_dir="$TMP_ROOT/basic"
  mkdir -p "$case_dir/state"

  run_asks "$case_dir" add task-a1 decision "Pick the deployment window" --source status:task-a1.status >/dev/null
  run_asks "$case_dir" add task-a1 decision "Pick the deployment window" --source status:task-a1.status >/dev/null
  file="$case_dir/data/captain-asks.md"

  [ "$(grep -cF 'Pick the deployment window' "$file")" -eq 1 ] \
    || fail "captain ask add was not idempotent"

  run_asks "$case_dir" resolve task-a1 decision --note "captain chose Friday" >/dev/null
  assert_grep '- [x]' "$file" "resolved ask did not move as checked"
  assert_grep 'captain chose Friday' "$file" "resolved ask did not include note"
  assert_no_grep '- [ ]' "$file" "resolved ask remained open"
  pass "captain asks add idempotently and resolve into the resolved section"
}

test_sync_from_state_adds_captain_relevant_statuses() {
  local case_dir file
  case_dir="$TMP_ROOT/sync"
  mkdir -p "$case_dir/state"
  printf '%s\n' 'needs-decision: choose A or B' > "$case_dir/state/decide-a1.status"
  printf '%s\n' 'blocked: missing GitHub login' > "$case_dir/state/block-b2.status"
  printf '%s\n' 'working: tests running' > "$case_dir/state/work-c3.status"

  run_asks "$case_dir" sync-from-state >/dev/null
  file="$case_dir/data/captain-asks.md"

  assert_grep 'decide-a1 | decision | needs-decision: choose A or B' "$file" "decision status was not synced"
  assert_grep 'block-b2 | blocker | blocked: missing GitHub login' "$file" "blocker status was not synced"
  assert_no_grep 'work-c3' "$file" "routine working status should not become a captain ask"
  pass "sync-from-state imports only captain-relevant pending asks"
}

test_pr_check_records_merge_ask_unless_yolo() {
  local case_dir fakebin head url file
  case_dir="$TMP_ROOT/pr-check"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$case_dir/state" "$case_dir/data"
  fm_git_worktree "$case_dir/project" "$case_dir/wt" fm/task-p1
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  url=https://github.com/example/repo/pull/12
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view") printf '%s\n' '$head'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"

  fm_write_meta "$case_dir/state/task-p1.meta" \
    "window=fm-task-p1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$fakebin:$PATH" \
    "$PR_CHECK" task-p1 "$url" >/dev/null
  file="$case_dir/data/captain-asks.md"
  assert_grep "task-p1 | merge | Review and merge PR $url" "$file" "pr-check did not record merge ask"

  fm_write_meta "$case_dir/state/task-y2.meta" \
    "window=fm-task-y2" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=on"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$fakebin:$PATH" \
    "$PR_CHECK" task-y2 "$url" >/dev/null

  assert_no_grep 'task-y2 | merge' "$file" "yolo task should not create a captain merge ask"
  pass "fm-pr-check records merge asks only when captain approval is required"
}

test_add_is_idempotent_and_resolve_moves_to_resolved
test_sync_from_state_adds_captain_relevant_statuses
test_pr_check_records_merge_ask_unless_yolo
