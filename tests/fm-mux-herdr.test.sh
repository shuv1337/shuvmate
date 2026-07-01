#!/usr/bin/env bash
# Behavior tests for the herdr backend in fm-mux.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-mux-herdr)

make_fake_herdr() {
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
  "tab create")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t9","label":"fm-herdr-a","workspace_id":"w1"},"root_pane":{"pane_id":"w1:p9","tab_id":"w1:t9","workspace_id":"w1"}}}'
    ;;
  "tab list")
    if grep -q '^tab create ' "$log" 2>/dev/null; then
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t10","label":"fm-herdr-a","workspace_id":"w1"}]}}'
    else
      printf '%s\n' '{"result":{"tabs":[]}}'
    fi
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p10","tab_id":"w1:t10","workspace_id":"w1"}]}}'
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1"}]}}'
    ;;
  "pane get")
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p9","agent_status":"idle"}}}'
    ;;
  "pane read")
    printf '%s\n' 'captured line'
    ;;
  "pane send-text"|"pane send-keys"|"tab close")
    printf '%s\n' '{"result":{"type":"ok"}}'
    ;;
  *)
    printf 'unexpected herdr call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

test_herdr_backend_contract() {
  local case_dir fakebin home target out log
  case_dir="$TMP_ROOT/case"
  mkdir -p "$case_dir/home/config" "$case_dir/cwd"
  printf '%s\n' herdr > "$case_dir/home/config/multiplexer"
  fakebin=$(make_fake_herdr "$case_dir")
  log="$case_dir/herdr.log"

  out=$(PATH="$fakebin:$BASE_PATH" HERDR_ENV=1 FM_HOME="$case_dir/home" "$ROOT/bin/fm-mux.sh" current)
  [ "$out" = herdr ] || fail "current did not prefer HERDR_ENV: $out"

  out=$(PATH="$fakebin:$BASE_PATH" HERDR_ENV=1 FM_HOME="$case_dir/home" "$ROOT/bin/fm-mux.sh" configured)
  [ "$out" = herdr ] || fail "configured did not accept config/multiplexer=herdr: $out"

  target=$(PATH="$fakebin:$BASE_PATH" HERDR_ENV=1 FM_HOME="$case_dir/home" FM_FAKE_HERDR_LOG="$log" \
    "$ROOT/bin/fm-mux.sh" create herdr herdr-a "$case_dir/cwd")
  [ "$target" = "herdr:w1/fm-herdr-a" ] || fail "unexpected create target: $target"

  out=$(PATH="$fakebin:$BASE_PATH" HERDR_ENV=1 FM_HOME="$case_dir/home" FM_FAKE_HERDR_LOG="$log" \
    "$ROOT/bin/fm-mux.sh" list herdr)
  [ "$out" = "$target" ] || fail "list herdr did not return target: $out"

  out=$(PATH="$fakebin:$BASE_PATH" HERDR_ENV=1 FM_HOME="$case_dir/home" FM_FAKE_HERDR_LOG="$log" \
    "$ROOT/bin/fm-mux.sh" resolve fm-herdr-a herdr)
  [ "$out" = "$target" ] || fail "resolve herdr did not return target: $out"

  PATH="$fakebin:$BASE_PATH" HERDR_ENV=1 FM_HOME="$case_dir/home" FM_FAKE_HERDR_LOG="$log" \
    "$ROOT/bin/fm-mux.sh" send-text "$target" "hello captain"
  PATH="$fakebin:$BASE_PATH" HERDR_ENV=1 FM_HOME="$case_dir/home" FM_FAKE_HERDR_LOG="$log" \
    "$ROOT/bin/fm-mux.sh" send-key "$target" Enter
  out=$(PATH="$fakebin:$BASE_PATH" HERDR_ENV=1 FM_HOME="$case_dir/home" FM_FAKE_HERDR_LOG="$log" \
    "$ROOT/bin/fm-mux.sh" capture "$target" 5)
  [ "$out" = "captured line" ] || fail "capture did not read herdr pane: $out"
  PATH="$fakebin:$BASE_PATH" HERDR_ENV=1 FM_HOME="$case_dir/home" FM_FAKE_HERDR_LOG="$log" \
    "$ROOT/bin/fm-mux.sh" kill "$target"

  assert_contains "$(cat "$log")" "tab create --workspace w1 --cwd $case_dir/cwd --label fm-herdr-a --no-focus" "create did not use herdr tab create"
  assert_contains "$(cat "$log")" "pane send-text w1:p10 hello captain" "send-text did not target resolved herdr pane"
  assert_contains "$(cat "$log")" "pane send-keys w1:p10 Enter" "send-key did not target resolved herdr pane"
  assert_contains "$(cat "$log")" "tab close w1:t10" "kill did not close resolved herdr tab"
  pass "fm-mux herdr backend creates, resolves, sends, captures, and closes native tabs"
}

make_fake_herdr_no_tabs() {
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
  "tab list")
    printf '%s\n' '{"result":{"tabs":[]}}'
    ;;
  "tab close")
    printf 'unexpected herdr call: %s\n' "$*" >&2
    exit 2
    ;;
  *)
    printf 'unexpected herdr call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

test_herdr_kill_already_gone_tab_is_idempotent() {
  local case_dir fakebin home target log status
  case_dir="$TMP_ROOT/already-gone"
  mkdir -p "$case_dir/home/config" "$case_dir/cwd"
  printf '%s\n' herdr > "$case_dir/home/config/multiplexer"
  fakebin=$(make_fake_herdr_no_tabs "$case_dir")
  log="$case_dir/herdr.log"
  target="herdr:w1/fm-herdr-gone"

  PATH="$fakebin:$BASE_PATH" HERDR_ENV=1 FM_HOME="$case_dir/home" FM_FAKE_HERDR_LOG="$log" \
    "$ROOT/bin/fm-mux.sh" kill "$target"
  status=$?
  [ "$status" -eq 0 ] || fail "kill on an already-gone herdr tab did not exit 0: $status"

  assert_not_contains "$(cat "$log")" "tab close" "kill on an already-gone tab must not attempt tab close"
  pass "fm-mux herdr kill is a safe no-op when the tab is already gone"
}

test_herdr_backend_contract
test_herdr_kill_already_gone_tab_is_idempotent
