#!/usr/bin/env bash
# Tests for the HTML operator view: fm-asks-html.sh rendering and the
# best-effort regeneration hook in fm-captain-asks.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RENDER="$ROOT/bin/fm-asks-html.sh"
ASKS="$ROOT/bin/fm-captain-asks.sh"
TMP_ROOT=$(fm_test_tmproot fm-asks-html-tests)

run_render() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$RENDER" "$@"
}

run_asks() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$ASKS" "$@"
}

write_fixtures() {
  local case_dir=$1
  mkdir -p "$case_dir/data" "$case_dir/state"
  cat > "$case_dir/data/captain-asks.md" <<'EOF'
# Captain asks

Open decisions, blockers, credentials, review or merge approvals, and any other captain-owned action.

## Open

- [ ] 2026-07-02 | task-a1 | decision | Choose <plan A> & plan B | source: status:task-a1.status <!-- fm-ask:task-a1:decision:1 -->
- [ ] 2026-07-02 | task-b2 | blocker | Need GitHub login <!-- fm-ask:task-b2:blocker:2 -->
- [ ] 2026-07-01 | task-c3 | merge | Review and merge PR https://github.com/example/repo/pull/12 | source: fm-pr-check <!-- fm-ask:task-c3:merge:3 -->
- [ ] 2026-07-01 | task-xss | merge | Suspicious URL https://evil.test/" onclick="alert(1) and https://evil.test/'onmouseover='alert(2) | source: status:task-xss.status <!-- fm-ask:task-xss:merge:4 -->
- a free-form hand-written note

## Resolved
- [x] 2026-06-30 | task-e5 | decision | Pick DB (postgres vs sqlite) (resolved 2026-07-01: postgres (captain: managed)) <!-- fm-ask:task-e5:decision:5 -->
EOF
  cat > "$case_dir/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] task-a1 - roll out the new gate (repo: alpha, since 2026-07-02)
- **task-bold** - bold-form in-flight item (repo: beta, since 2026-07-01)

## Queued
- [ ] task-q1 - follow-up work (repo: alpha) blocked-by: task-a1 - same subsystem

## Done
- [x] task-z9 - shipped the thing - https://github.com/example/repo/pull/11 (merged 2026-07-01)
EOF
}

test_renders_asks_and_backlog_with_escaping() {
  local case_dir out
  case_dir="$TMP_ROOT/render"
  write_fixtures "$case_dir"

  run_render "$case_dir" >/dev/null
  out="$case_dir/state/captain-view.html"
  assert_present "$out" "renderer did not write the HTML view"

  assert_grep 'badge-decision">decision<' "$out" "decision badge missing"
  assert_grep 'badge-blocker">blocker<' "$out" "blocker badge missing"
  assert_grep 'badge-merge">merge<' "$out" "merge badge missing"
  assert_grep 'Choose &lt;plan A&gt; &amp; plan B' "$out" "summary was not HTML-escaped"
  assert_no_grep '<plan A>' "$out" "raw markup leaked into the HTML"
  assert_grep '<a href="https://github.com/example/repo/pull/12">' "$out" "PR URL was not linkified"
  assert_grep '<a href="https://evil.test/">https://evil.test/</a>" onclick="alert(1)' "$out" "quoted URL prefix was not safely linkified"
  assert_grep '<a href="https://evil.test/">https://evil.test/</a>'"'"'onmouseover='"'"'alert(2)' "$out" "single-quoted URL prefix was not safely linkified"
  assert_no_grep '<a href="https://evil.test/" onclick=' "$out" "double quote broke out of href attribute"
  assert_no_grep '<a href="https://evil.test/'"'"'onmouseover=' "$out" "single quote stayed inside href attribute"
  assert_grep 'a free-form hand-written note' "$out" "free-form open bullet was dropped"
  assert_grep 'resolved 2026-07-01: postgres (captain: managed)' "$out" "resolved note missing"

  assert_grep '<span class="task-id">task-a1</span>' "$out" "in-flight item missing"
  assert_grep '<span class="task-id">task-bold</span>' "$out" "bold-form in-flight id was not parsed"
  assert_grep 'task task-blocked' "$out" "blocked queued item was not flagged"
  assert_grep 'repo: alpha, since 2026-07-02' "$out" "task metadata missing"
  assert_grep '5 open ask(s)' "$out" "open-ask count chip wrong"
  assert_grep '2 in flight' "$out" "in-flight count chip wrong"
  pass "renderer escapes, linkifies, and groups asks and backlog"
}

test_renders_empty_state_without_data_files() {
  local case_dir out
  case_dir="$TMP_ROOT/empty"
  mkdir -p "$case_dir/data" "$case_dir/state"

  run_render "$case_dir" >/dev/null || fail "renderer failed on missing data files"
  out="$case_dir/state/captain-view.html"
  assert_grep 'No ledger yet' "$out" "missing asks file did not render empty state"
  assert_grep 'No backlog file yet' "$out" "missing backlog file did not render empty state"
  assert_grep '0 open ask(s)' "$out" "empty view should count zero open asks"
  pass "renderer handles missing data files with empty states"
}

test_captain_asks_mutations_regenerate_view() {
  local case_dir out
  case_dir="$TMP_ROOT/hook"
  mkdir -p "$case_dir/data" "$case_dir/state"

  run_asks "$case_dir" add task-h1 decision "Pick the deployment window" >/dev/null
  out="$case_dir/state/captain-view.html"
  assert_present "$out" "add did not regenerate the HTML view"
  assert_grep 'Pick the deployment window' "$out" "regenerated view is missing the new ask"

  run_asks "$case_dir" resolve task-h1 decision --note "captain chose Friday" >/dev/null
  assert_grep 'captain chose Friday' "$out" "resolve did not refresh the HTML view"
  assert_grep '0 open ask(s)' "$out" "resolved ask still counted as open in the view"
  pass "fm-captain-asks.sh mutations regenerate the HTML view"
}

test_render_failure_never_breaks_the_mutation() {
  local case_dir output
  case_dir="$TMP_ROOT/nonfatal"
  mkdir -p "$case_dir/data" "$case_dir/state"
  chmod 555 "$case_dir/state"

  output=$(run_asks "$case_dir" add task-n1 blocker "Need a credential" 2>&1)
  expect_code 0 $? "add must succeed even when the view cannot be written"
  assert_contains "$output" "tracked: task-n1 blocker" "add output changed under render failure"
  assert_absent "$case_dir/state/captain-view.html" "view should not exist in read-only state dir"
  chmod 755 "$case_dir/state"
  pass "render failure is non-fatal and leaves the CLI output unchanged"
}

test_renders_asks_and_backlog_with_escaping
test_renders_empty_state_without_data_files
test_captain_asks_mutations_regenerate_view
test_render_failure_never_breaks_the_mutation
