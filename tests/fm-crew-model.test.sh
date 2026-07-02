#!/usr/bin/env bash
# Behavior tests for crew model resolution (fm-harness.sh crew-model) and the
# claude launch template's --model wiring in fm-spawn.sh.
#
# The resolver decides which claude model a spawned crew launches on. Without it,
# claude crews fell through to the CLI's own default (Fable, the priciest tier)
# for routine coding work. These cases pin the resolution order
# (FM_CREW_MODEL env > config/crew-model > "opus" baseline) and guard the spawn
# template against silently dropping the --model flag again.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-model)

# Clear any ambient per-spawn override so baseline rows own their environment;
# rows that exercise the override set FM_CREW_MODEL inline on the call.
unset FM_CREW_MODEL

# Resolve crew-model against an isolated config dir supplied per row.
run_crew_model() {
  FM_CONFIG_OVERRIDE="$1" "$HARNESS" crew-model 2>&1
}

# Resolution order: unset env + absent/blank/default config -> "opus"; a config
# token wins over the baseline; FM_CREW_MODEL wins over the config token.
test_resolution_order() {
  local cfg="$TMP_ROOT/config"
  mkdir -p "$cfg"

  # Absent config file -> baseline.
  assert_contains "$(run_crew_model "$cfg")" "opus" "absent config resolves to opus baseline"

  # Literal "default" -> baseline.
  printf 'default\n' > "$cfg/crew-model"
  assert_contains "$(run_crew_model "$cfg")" "opus" "'default' token resolves to opus baseline"

  # Blank file -> baseline.
  printf '   \n' > "$cfg/crew-model"
  assert_contains "$(run_crew_model "$cfg")" "opus" "blank config resolves to opus baseline"

  # A real token wins over the baseline (and surrounding whitespace is trimmed).
  printf '  haiku \n' > "$cfg/crew-model"
  [ "$(run_crew_model "$cfg")" = "haiku" ] || fail "config token 'haiku' not resolved cleanly"

  # FM_CREW_MODEL (per-spawn override) beats the config token.
  [ "$(FM_CREW_MODEL=sonnet run_crew_model "$cfg")" = "sonnet" ] \
    || fail "FM_CREW_MODEL did not override config/crew-model"

  # FM_CREW_MODEL beats an absent config too.
  rm -f "$cfg/crew-model"
  [ "$(FM_CREW_MODEL=fable run_crew_model "$cfg")" = "fable" ] \
    || fail "FM_CREW_MODEL did not resolve when config is absent"

  pass "crew-model resolves FM_CREW_MODEL > config/crew-model > opus baseline"
}

# An unknown verb prints usage listing crew-model and exits non-zero.
test_usage_lists_crew_model() {
  local out status
  out=$("$HARNESS" bogus-verb 2>&1)
  status=$?
  expect_code 2 "$status" "unknown verb exit code"
  assert_contains "$out" "crew-model" "usage advertises the crew-model verb"
  pass "unknown verb prints usage including crew-model and exits 2"
}

# The claude launch template must carry --model __MODEL__ and fm-spawn must
# substitute the placeholder, so the model flag cannot silently regress away.
test_spawn_wires_model_placeholder() {
  grep -F -- '--model __MODEL__' "$SPAWN" >/dev/null \
    || fail "claude launch template dropped --model __MODEL__"
  # shellcheck disable=SC2016  # literal grep pattern; the ${...} is source text, not an expansion
  grep -F -- 'LAUNCH=${LAUNCH//__MODEL__/' "$SPAWN" >/dev/null \
    || fail "fm-spawn no longer substitutes the __MODEL__ placeholder"
  pass "claude template carries --model __MODEL__ and fm-spawn substitutes it"
}

test_resolution_order
test_usage_lists_crew_model
test_spawn_wires_model_placeholder
