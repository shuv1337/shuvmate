#!/usr/bin/env bash
# Send one line of literal text to a crewmate task surface, then Enter.
# Usage: fm-send.sh <window-or-target> <text...>
#   <window-or-target> may be a bare task name (fm-xyz), resolved through this
#   home's state/<id>.meta (mux= and target=), an explicit session:window, or a
#   backend target. Resolution and delivery go through fm-mux.sh so tmux
#   windows, zellij tabs, and herdr tabs are handled.
# Special keys instead of text: fm-send.sh <window-or-target> --key Escape   (or Enter, C-c, ...)
#
# Text submission is verified on the tmux backend: the line is typed ONCE, then
# Enter is sent and retried (Enter only, never retyped) until the composer clears.
# If a swallowed Enter is positively confirmed (the text is still sitting in the
# composer after all retries), fm-send exits NON-ZERO so the caller knows the
# steer did not land instead of silently leaving an unsubmitted instruction
# (incident afk-invx-i5). The composer/submit logic is shared with the away-mode
# daemon via bin/fm-tmux-lib.sh. Tune with FM_SEND_RETRIES (default 3) /
# FM_SEND_SLEEP (0.4). The zellij backend uses fm-mux.sh send-text/send-key with a
# pre-Enter settle; its TUIs do not expose the tmux composer-introspection
# primitives the verified-submit core needs. Herdr follows that same generic
# backend path, with native pane send/read/close calls inside fm-mux.sh.
# Slash commands, and codex `$...` skill invocations resolved through harness
# meta, get a longer pre-Enter settle so completion popups do not swallow Enter.
#
# From-firstmate marker: when the resolved target is a bare `fm-<id>` whose meta
# records kind=secondmate, the text is prefixed with the from-firstmate marker
# (bin/fm-marker-lib.sh) so the secondmate routes its reply via its status file
# or a status-pointed doc instead of stranding it in chat the main firstmate
# never reads. A crewmate/scout target, an explicit session:window escape-hatch
# target, and the --key path are never marked - their behavior is unchanged.
# After a successful text submit fm-send pauses FM_SEND_SETTLE seconds (default 1,
# 0 disables) before returning: a cleared composer only proves the text was
# submitted, but the harness needs a beat to spin up the turn before its busy
# footer appears, so an immediate peek would otherwise see the stale idle pane.
# The pause is fm-send-only; the shared submit core (used by the away-mode daemon,
# which only needs "submitted") does not pay it, and the --key path is unaffected.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MUX="$SCRIPT_DIR/fm-mux.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

RAW_TARGET=$1
T=$("$MUX" resolve-task "$1")
shift

# Mark a from-firstmate -> secondmate request. Only a bare `fm-<id>` target,
# resolved through this home's meta and recording kind=secondmate, is marked: the
# secondmate then routes its reply via the status path (see fm-marker-lib.sh).
# An explicit session:window target (the escape hatch for windows outside this
# home) and any crewmate/scout target are left unmarked, and so is the --key path.
MARK_PREFIX=""
case "$RAW_TARGET" in
  fm-*)
    meta="$STATE/${RAW_TARGET#fm-}.meta"
    if [ -f "$meta" ] && grep -q '^kind=secondmate$' "$meta" 2>/dev/null; then
      MARK_PREFIX="$FM_FROMFIRST_MARK"
    fi
    ;;
esac

# Resolve the target's harness from its meta (recorded by fm-spawn), used only to
# scope the codex `$<skill>` popup-settle below. A bare fm-<id> target carries
# meta; an explicit session:window escape-hatch target has none, so its harness is
# unknown and treated as non-codex (the safe default that keeps the fast path).
TARGET_HARNESS=""
case "$RAW_TARGET" in
  fm-*)
    meta="$STATE/${RAW_TARGET#fm-}.meta"
    if [ -f "$meta" ]; then
      TARGET_HARNESS=$(grep '^harness=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    fi
    ;;
esac

if [ "${1:-}" = "--key" ]; then
  "$MUX" send-key "$T" "$2"
else
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing, so give the popup time to settle before
  # the (retried) Enter. Codex opens the same kind of popup for a `$<skill>`
  # invocation, so a `$...` message to a codex target gets the same settle. That
  # `$` case is scoped to codex on purpose: unlike `/`, a leading `$` commonly
  # starts ordinary text ("$5/month", "$HOME"), so a universal `$` rule would
  # needlessly slow plain text to claude/opencode/pi. The retried Enter in
  # fm_tmux_submit_core still backs the settle up either way.
  case "$*" in
    /*) settle=1.2 ;;
    \$*)
      if [ "$TARGET_HARNESS" = codex ]; then settle=1.2; else settle=0.3; fi
      ;;
    *) settle=0.3 ;;
  esac
  retries=${FM_SEND_RETRIES:-3}
  sleep_s=${FM_SEND_SLEEP:-0.4}
  case "$T" in
    tmux:*)
      # tmux backend: type once, submit, verify. Lenient: only a positively
      # confirmed swallow (text still in the composer) is an error; an unreadable
      # pane is assumed sent. fm_tmux_submit_core wants the bare session:window.
      win=${T#tmux:}
      verdict=$(fm_tmux_submit_core "$win" "$MARK_PREFIX$*" "$retries" "$sleep_s" "$settle")
      case "$verdict" in
        pending)
          echo "error: text not submitted to $T (Enter swallowed; text left in composer)" >&2
          exit 1
          ;;
        send-failed)
          echo "error: text not sent to $T (tmux send-keys failed)" >&2
          exit 1
          ;;
      esac
      ;;
    *)
      # zellij (and any non-tmux) backend: deliver through the mux helper, settle
      # for completion popups, then submit. The verified composer introspection is
      # tmux-only, so this path trusts the backend's write + Enter.
      "$MUX" send-text "$T" "$MARK_PREFIX$*"
      sleep "$settle"
      "$MUX" send-key "$T" Enter
      ;;
  esac
  # Submit landed (no error above). The cleared composer only proves the text was
  # submitted; the harness still needs a beat to spin up the turn before its busy
  # footer shows. Pause so an immediate peek catches the crewmate actually working
  # instead of the stale idle pane. FM_SEND_SETTLE=0 disables it. Scoped to this
  # path only, never the shared submit core.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
