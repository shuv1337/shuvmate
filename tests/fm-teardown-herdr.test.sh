#!/usr/bin/env bash
# Behavior tests for tearing down Herdr-native crew worktrees.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-teardown-herdr)

make_fakebin() {
  local dir=$1 fakebin log
  fakebin=$(fm_fakebin "$dir")
  log="$dir/herdr.log"
  : > "$log"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_HERDR_LOG:?}
printf '%s\n' "$*" >> "$log"
case "${1:-} ${2:-}" in
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w9","label":"fm-herdr-teardown"}]}}'
    ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","label":"1","workspace_id":"w9"}]}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"w9:p1","tab_id":"w9:t1","workspace_id":"w9"}]}}'
    ;;
  "worktree remove")
    git -C "$FM_FAKE_HERDR_PROJECT" worktree remove --force "$FM_FAKE_HERDR_WT" >/dev/null 2>&1 || true
    printf '%s\n' '{"result":{"type":"ok"}}'
    ;;
  "tab close")
    printf '%s\n' '{"result":{"type":"ok"}}'
    ;;
  *)
    printf 'unexpected herdr call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'unexpected treehouse call: %s\n' "$*" >&2
exit 99
SH
  chmod +x "$fakebin/herdr" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

test_teardown_removes_herdr_native_worktree() {
  local case_dir home project wt fakebin log out status meta
  case_dir="$TMP_ROOT/native"
  home="$case_dir/home"
  project="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/state" "$home/data/herdr-teardown"
  fm_git_init_commit "$project"
  git -C "$project" worktree add --quiet -b fm/herdr-teardown "$wt"
  meta="$home/state/herdr-teardown.meta"
  fm_write_meta "$meta" \
    "mux=herdr" \
    "target=herdr:fm-herdr-teardown/1" \
    "window=fm-herdr-teardown" \
    "worktree=$wt" \
    "project=$project" \
    "harness=codex" \
    "kind=scout" \
    "mode=no-mistakes" \
    "yolo=off"
  fakebin=$(make_fakebin "$case_dir")
  log="$case_dir/herdr.log"

  out=$(PATH="$fakebin:$BASE_PATH" HERDR_ENV=1 FM_HOME="$home" \
    FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_PROJECT="$project" FM_FAKE_HERDR_WT="$wt" \
    "$ROOT/bin/fm-teardown.sh" herdr-teardown --force 2>&1)
  status=$?
  expect_code 0 "$status" "herdr native teardown should succeed"
  assert_contains "$out" "teardown herdr-teardown complete" "teardown did not report completion"
  assert_contains "$(cat "$log")" "worktree remove --workspace w9 --force --json" "teardown did not remove the native Herdr worktree"
  assert_not_contains "$(cat "$log")" "treehouse" "herdr native teardown should not call treehouse"
  # Regression: remove-worktree only pools/resets the linked worktree; it is not
  # guaranteed to also close the herdr tab (and the agent process inside it), so
  # teardown must unconditionally close the tab through the same kill path used
  # by tmux/zellij, instead of assuming remove-worktree already did it.
  assert_contains "$(cat "$log")" "tab close w9:t1" "teardown did not close the herdr tab after removing the worktree"
  [ ! -e "$meta" ] || fail "teardown did not remove meta"
  [ ! -d "$wt" ] || fail "teardown did not remove native worktree path"
  pass "fm-teardown removes Herdr-native worktrees through Herdr"
}

test_teardown_removes_herdr_native_worktree
