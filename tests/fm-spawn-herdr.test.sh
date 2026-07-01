#!/usr/bin/env bash
# Behavior tests for Herdr-native crew spawning.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr)

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
  "pane current")
    printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1"}}}'
    ;;
  "worktree list")
    printf '%s\n' '{"result":{"source":{"repo_key":"fake","repo_name":"project","repo_root":"'"$FM_FAKE_HERDR_PROJECT"'","source_checkout_path":"'"$FM_FAKE_HERDR_PROJECT"'","source_workspace_id":"w1"},"worktrees":[]}}'
    ;;
  "worktree create")
    git -C "$FM_FAKE_HERDR_PROJECT" worktree add --quiet -b worktree/fake "$FM_FAKE_HERDR_WT" >/dev/null
    printf '%s\n' '{"result":{"root_pane":{"pane_id":"w9:p1","tab_id":"w9:t1","workspace_id":"w9","cwd":"'"$FM_FAKE_HERDR_WT"'"},"tab":{"tab_id":"w9:t1","label":"1","workspace_id":"w9"},"workspace":{"workspace_id":"w9","label":"fm-spawn-native","worktree":{"checkout_path":"'"$FM_FAKE_HERDR_WT"'","is_linked_worktree":true}},"worktree":{"path":"'"$FM_FAKE_HERDR_WT"'","branch":"worktree/fake","is_detached":false}}}'
    ;;
  "workspace list")
    if grep -q '^worktree create ' "$log" 2>/dev/null; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"project"},{"workspace_id":"w9","label":"fm-spawn-native"}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"project"}]}}'
    fi
    ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w9:t1","label":"1","workspace_id":"w9"}]}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"w9:p1","tab_id":"w9:t1","workspace_id":"w9"}]}}'
    ;;
  "pane send-text"|"pane send-keys")
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

test_spawn_herdr_uses_native_worktree() {
  local case_dir home project wt fakebin log out status branch meta
  case_dir="$TMP_ROOT/native"
  home="$case_dir/home"
  project="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/config" "$home/data/spawn-native"
  printf '%s\n' herdr > "$home/config/multiplexer"
  printf 'brief\n' > "$home/data/spawn-native/brief.md"
  fm_git_init_commit "$project"
  fakebin=$(make_fakebin "$case_dir")
  log="$case_dir/herdr.log"

  out=$(PATH="$fakebin:$BASE_PATH" HERDR_ENV=1 FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_PROJECT="$project" FM_FAKE_HERDR_WT="$wt" \
    "$ROOT/bin/fm-spawn.sh" spawn-native "$project" codex 2>&1)
  status=$?
  expect_code 0 "$status" "herdr native spawn should succeed"
  assert_contains "$out" "spawned spawn-native" "spawn did not report success"
  assert_contains "$out" "worktree=$wt" "spawn did not report the Herdr-native worktree"
  assert_not_contains "$(cat "$log")" "treehouse" "herdr spawn should not call treehouse"
  assert_contains "$(cat "$log")" "worktree create --workspace w1 --label fm-spawn-native --no-focus --json" "spawn did not create a Herdr-native worktree from the project workspace"
  assert_contains "$(cat "$log")" "pane send-text w9:p1 codex" "spawn did not launch the harness in the native worktree pane"
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -z "$branch" ] || fail "spawned Herdr worktree was not detached before launch: $branch"
  meta="$home/state/spawn-native.meta"
  assert_contains "$(cat "$meta")" "mux=herdr" "meta did not record herdr mux"
  assert_contains "$(cat "$meta")" "target=herdr:fm-spawn-native/1" "meta did not record stable Herdr target"
  assert_contains "$(cat "$meta")" "worktree=$wt" "meta did not record native worktree"
  pass "fm-spawn herdr uses a native linked worktree instead of treehouse"
}

test_spawn_herdr_uses_native_worktree
