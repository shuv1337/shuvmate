# Plan: Add zellij as an alternative firstmate multiplexer

## Goal

Add zellij support alongside the existing tmux support so firstmate can supervise crewmate sessions through either multiplexer.

The implementation should keep tmux as the default, preserve compatibility with existing `state/*.meta` files, and make the multiplexer choice explicit enough that every supervision script can route operations to the correct backend.

## Current state summary

firstmate currently treats tmux as the only ground-truth terminal surface.

| Area | Current tmux dependency |
|---|---|
| `bin/fm-bootstrap.sh` | Requires `tmux` in `TOOLS` and only offers a tmux install command. |
| `bin/fm-spawn.sh` | Creates a tmux session/window, sends `treehouse get`, polls `#{pane_current_path}`, records `window=<session:window>`, and launches the harness with `tmux send-keys`. |
| `bin/fm-send.sh` | Resolves a bare `fm-*` name via `tmux list-windows -a`, then sends literal text or keys with `tmux send-keys`. |
| `bin/fm-peek.sh` | Resolves a tmux window and reads pane content with `tmux capture-pane`. |
| `bin/fm-watch.sh` | Lists `fm-*` tmux windows and hashes `tmux capture-pane` output to detect stale panes. |
| `bin/fm-teardown.sh` | Kills the tmux window with `tmux kill-window`. |
| `bin/fm-guard.sh` | Multiplexer-neutral; only checks state files. |
| `bin/fm-pr-check.sh` | Multiplexer-neutral apart from calling `fm-guard.sh`. |
| `bin/fm-promote.sh` | Multiplexer-neutral apart from examples that assume `fm-send.sh fm-<id>`. |
| `bin/fm-review-diff.sh` | Multiplexer-neutral apart from calling `fm-guard.sh`. |
| `bin/fm-brief.sh` | Multiplexer-neutral; crewmates communicate through status files. |
| `bin/fm-fleet-sync.sh` | Multiplexer-neutral apart from calling `fm-guard.sh`. |
| `bin/fm-harness.sh` | Harness-only; does not need multiplexer awareness. |
| `bin/fm-lock.sh` | Harness-only; does not need multiplexer awareness. |
| `bin/fm-merge-local.sh` | Multiplexer-neutral apart from calling `fm-guard.sh`. |
| `README.md` | Describes tmux as a prerequisite, says every crewmate lives in a tmux window, and documents tmux-specific smoke tests and environment text. |
| `AGENTS.md` / `CLAUDE.md` | Recovery, spawn, supervision, and teardown instructions all name tmux windows as the single source of truth. |
| `CONTRIBUTING.md` | No direct tmux dependency, but requires shell script headers and `shellcheck bin/*.sh`. |
| `.github/workflows/ci.yml` | Runs `shellcheck bin/*.sh` and repo invariant checks only. |
| `.github/workflows/no-mistakes-required.yml` | No multiplexer dependency. |
| `.agents/skills/no-mistakes/SKILL.md` | No multiplexer dependency. |

## Design principles

- Keep tmux behavior unchanged unless `zellij` is explicitly selected or tmux is unavailable and zellij is configured as the fallback.
- Treat the multiplexer as a backend with a small command surface: create task tab/window, resolve task target, send text, send key, capture screen, list task targets, and kill task target.
- Store the selected backend in task metadata so a task spawned in tmux is always supervised and torn down through tmux, while a task spawned in zellij is always supervised and torn down through zellij.
- Preserve old metadata compatibility by treating missing `mux=` as `tmux`.
- Avoid rewriting project delivery, harness adapters, status files, turn-end hooks, or treehouse safety checks.
- Do not require zellij in CI unless tests explicitly need it; static validation should remain available on machines without zellij.
- **Settle the two feasibility unknowns before writing backend code.** Two zellij behaviors can invalidate the entire design, and neither is established in this repo: (1) whether a detached/background zellij session can be created and driven entirely via the CLI with no attached client, and (2) whether text injected into a harness TUI arrives as typed input that auto-submits, rather than as a bracketed-paste blob the TUI buffers or mishandles. The spike (task 2) is a hard gate: if either fails, the scope shrinks to "zellij supported only when firstmate itself runs inside zellij" (see the fallback under Proposed user-facing behavior), and the outside-zellij detached path is dropped rather than shipped broken.
- **Preserve exact-byte input fidelity across the new helper boundary.** Today `fm-send.sh`/`fm-spawn.sh` deliver input with a single `tmux send-keys -l "$*"`. Routing the same text through an extra `fm-mux.sh send-text` process adds a layer where spaces, quotes, `$`, and backslashes in a brief or message can be mangled. The helper must pass text through byte-for-byte; this is a correctness requirement, not a nicety.

## Proposed user-facing behavior

### Configuration

Add a local gitignored file:

```text
config/multiplexer
```

Supported values:

| Value | Meaning |
|---|---|
| `tmux` | Use tmux for new crewmate sessions. |
| `zellij` | Use zellij for new crewmate sessions. |
| `default` or missing | Keep current behavior: prefer tmux-compatible operation. |

This mirrors `config/crew-harness` without changing harness selection.

### Bootstrap

`bin/fm-bootstrap.sh` should report missing multiplexer tooling based on the chosen multiplexer.

- If `config/multiplexer` is missing or `default`, keep requiring `tmux` to avoid changing existing installs.
- If `config/multiplexer` is `zellij`, require `zellij` instead of `tmux`.
- If `config/multiplexer` has an unknown value, print a clear problem line and do not guess.

Two concrete edits, not just hint text. The current `TOOLS` is a fixed string (`bin/fm-bootstrap.sh:64`) and `install_cmd` is a `case` (`:54`):

- Make the multiplexer entry in `TOOLS` conditional: resolve the configured multiplexer and substitute `tmux` ↔ `zellij` in the required-tools list, rather than always requiring `tmux`.
- Add a `zellij)` arm to `install_cmd` alongside the existing `tmux|node|gh)` arm so the missing-tool line carries a real install command.

Install hints should include:

```sh
brew install zellij  # or the platform's package manager
```

Linux package-manager wording can remain generic, matching the current tmux install hint style.

### Runtime names

Keep task IDs and visible tab/window names as `fm-<id>`.

For zellij, represent each task as a tab named `fm-<id>` inside a session.

Default zellij session selection should be:

- If firstmate is already inside zellij, create tabs in the current zellij session.
- If firstmate is outside zellij, create or reuse a detached `firstmate` zellij session.

The outside-zellij case depends on the spike's first gate (detached session control). zellij is architected around an attached client, and `tmux new-session -d` — a genuinely detached, CLI-pokeable session — has no guaranteed zellij analogue; `zellij attach --create` typically attaches a client rather than leaving a background session to drive. If the spike shows a detached zellij session cannot be reliably created and driven via `zellij action` with no client attached, fall back as below.

### Fallback if detached zellij control is not feasible

If gate 1 fails, do not ship a broken outside-zellij path. Instead:

- Support zellij **only when firstmate is already running inside a zellij session**, creating task tabs in that session.
- When `config/multiplexer` is `zellij` but firstmate is outside zellij, bootstrap and spawn should print a clear, actionable line ("zellij selected but firstmate is not inside a zellij session; start firstmate inside zellij or set `config/multiplexer` to tmux") and refuse to spawn rather than silently degrading.
- tmux remains the default and the only fully outside-multiplexer-capable backend.

This keeps zellij useful for captains who live inside zellij without overpromising a detached-control capability the tool may not support.

## Implementation tasks

### 1. Add a multiplexer backend helper

Create a new shared helper, probably:

```text
bin/fm-mux.sh
```

This helper should encapsulate the tmux/zellij command differences instead of duplicating backend branches across `fm-spawn.sh`, `fm-send.sh`, `fm-peek.sh`, `fm-watch.sh`, and `fm-teardown.sh`.

Required subcommands:

```sh
bin/fm-mux.sh current
bin/fm-mux.sh configured
bin/fm-mux.sh ensure-session <mux>
bin/fm-mux.sh create <mux> <task-id> <cwd>
bin/fm-mux.sh list [<mux>]
bin/fm-mux.sh resolve <target-or-task-name> [<mux>]
bin/fm-mux.sh send-text <target> <text>
bin/fm-mux.sh send-key <target> <key>
bin/fm-mux.sh capture <target> <lines>
bin/fm-mux.sh kill <target>
```

The exact names can change during implementation, but the abstraction should cover those operations.

**Input fidelity across the boundary.** `send-text` must deliver its payload byte-for-byte to the underlying backend, with no shell re-expansion of the text. Today `fm-send.sh` runs `tmux send-keys -t "$T" -l "$*"` in one process; introducing `fm-mux.sh send-text` adds an exec boundary where a brief or message containing spaces, quotes, `$`, or backslashes can be mangled. Pass the text as a single argument (`"$*"` captured once and forwarded as one positional), never re-split or `eval` it, and add a test that round-trips a payload containing `' " $ \ space` through `send-text` into a scratch pane and reads it back unchanged.

**`list` enumeration must be explicit about scope.** For tmux, `list` enumerates `:fm-` windows across all sessions (`tmux list-windows -a`). For zellij, listing has no global "all tabs everywhere" primitive — tabs are per-session — so `list` must decide which session(s) to scan. Define it concretely: scan the current zellij session if firstmate is inside one, plus the `firstmate` session if it exists, and enumerate `fm-` tabs within those via `list-tabs --json`. `list all` (used by the watcher and recovery) unions the tmux result and the zellij result so mixed-backend fleets are fully enumerated; document that any zellij task tab living in a session outside that set is intentionally out of scope.

The helper should return structured target strings that include the backend, for example:

```text
tmux:session:window
zellij:session:tab_id:pane_id
```

Task metadata should store both a human-readable display name and a machine target:

```text
mux=tmux
window=firstmate:fm-example-a1
target=tmux:firstmate:fm-example-a1
```

For zellij:

```text
mux=zellij
window=firstmate:fm-example-a1
target=zellij:firstmate:<tab-id>:<pane-id>
```

Keep `window=` for compatibility and captain-facing/debug text, but route scripts through `mux=` and `target=`.

For existing tasks where `mux=` and `target=` are absent, infer:

```text
mux=tmux
target=tmux:<window>
```

### 2. Gating spike: prove zellij feasibility before writing backend code

This is a **hard gate**, not a warm-up. Two of its checks can invalidate the design; settle them first and let their outcome decide the shape of the rest of the work. Run a small disposable manual spike and document the verified command forms in comments or tests.

The local zellij version observed during planning is `0.45.0`.

#### Spike outcome (verified 2026-06-18, zellij 0.45.0, from outside any zellij session)

**Both gates PASS. Full zellij support is viable, including the outside-zellij detached path; the inside-zellij-only fallback is not triggered.** Verified command forms — treat these as the locked contract for the zellij backend:

| Operation | Verified command | Notes |
|---|---|---|
| Create detached session | `zellij attach --create-background <session>` | Stays alive with no client attached; all actions below work against it. |
| Create task tab | `zellij --session <s> action new-tab --name fm-<id> --cwd <dir>` | Does **not** return a pane id. |
| Discover panes | `zellij --session <s> action list-panes` | Columns `PANE_ID TYPE TITLE`; TITLE carries the shell cwd. Map tab→pane via this plus `list-tabs` (`TAB_ID POSITION NAME`). |
| Send literal text | `zellij --session <s> action write-chars -p <pane> '<text>'` | Byte-faithful: `a b$c"d'e\f\|g;h` rendered verbatim. Works on non-focused panes/tabs. |
| **Submit (Enter)** | `zellij --session <s> action send-keys -p <pane> "Enter"` | **Critical:** `write -p <pane> 10` (LF) inserts a newline in the harness editor and does NOT submit; CR is required. `write ... 13` works, but `send-keys "Enter"` is the clean named-key form — use it. |
| Interrupt (Escape) | `zellij --session <s> action send-keys -p <pane> "Esc"` | Cleared a running claude turn. |
| Capture | `zellij --session <s> action dump-screen -p <pane>` | Streams to STDOUT, clean pane content (no zellij chrome); footer/busy indicator captured intact. `-f` adds full scrollback. |
| Scoped teardown | `zellij --session <s> action close-tab-by-id <tab-id>` | Closes only that tab. **Do not** use bare `close-tab` — it closes the *focused* tab, ambiguous in a detached session. |
| Kill session | `zellij delete-session <session> --force` | Removed only the spike session; unrelated sessions untouched. |

Implementation rules that fall out of this: **use `write-chars` for all literal text and `send-keys` for named keys (`Enter`, `Esc`); never use `write <N>` for Enter, and never use `paste` (it injects bracketed-paste mode).** `dump-screen -p` is the capture primitive for both `fm-peek` and the watcher. The pane TITLE reflecting cwd is shell-integration-dependent, so keep the portable ready-file probe (task 3) rather than relying on it.

Known useful CLI surfaces from `zellij --help` and `zellij action --help`:

```sh
zellij list-sessions --short --no-formatting
zellij attach --create-background <session>
zellij --session <session> action new-tab --name <name> --cwd <cwd>
zellij --session <session> action list-tabs            # TAB_ID POSITION NAME
zellij --session <session> action list-panes           # PANE_ID TYPE TITLE
zellij --session <session> action write-chars -p <pane-id> '<text>'
zellij --session <session> action send-keys  -p <pane-id> "Enter"   # NOT write 10
zellij --session <session> action send-keys  -p <pane-id> "Esc"
zellij --session <session> action dump-screen -p <pane-id>          # to STDOUT
zellij --session <session> action close-tab-by-id <tab-id>          # NOT bare close-tab
zellij delete-session <session> --force
```

These forms were verified empirically in the spike outcome above; the checklists below are retained as the reproduction script.

#### Gate 1 — detached session control (decides whether the outside-zellij path exists)

zellij is built around an attached client; a genuinely detached, CLI-only session is the unknown that most threatens the design.

- [x] From **outside** any zellij session, create a session that stays alive with no client attached, and drive it purely via `zellij --session <name> action ...`. **PASS** — `zellij attach --create-background`.
- [x] Confirm `new-tab`, `write-chars`, `dump-screen`, and `close-tab-by-id` all work against that no-client-attached session. **PASS** — all verified, including pane-id targeting of non-focused tabs.
- [x] If they do not: **stop and take the fallback**. Not triggered — detached control works.

#### Gate 2 — input fidelity to the harness TUI (decides whether control is reliable at all)

Sending the brief and slash commands is firstmate's entire control channel. The harness TUIs (claude/codex/opencode/pi) commonly run in bracketed-paste mode, where pasted text is handled differently from typed input — it can fail to auto-submit, drop the trailing Enter, or arrive as one blob.

- [x] Launch a **real harness** (claude) in a zellij task tab, not a bare shell. **PASS** — claude TUI came up and rendered its prompt box.
- [x] Send a line of text followed by Enter and confirm the harness receives it as typed input and **auto-submits**. **PASS, with correction** — `write-chars` types the text faithfully, but `write 10` (LF) only inserted a newline in the editor; submission required CR. Use `send-keys "Enter"`. claude replied to the injected prompt.
- [x] Confirm the interrupt key reaches a running turn. **PASS** — `send-keys "Esc"` cleared an in-progress claude turn.
- [x] Compare `write-chars` against `action paste`; `paste` is documented as bracketed-paste mode, `write-chars` is direct character input — `write-chars` chosen. **Do not** use `paste`.
- [ ] Slash-command popup timing (`/no-mistakes` for claude, `$no-mistakes` for codex) over zellij — not exercised in the spike; carry the `fm-send.sh` slash-delay into the zellij path and verify during task 5. Low risk: text delivery and submit are proven; only the popup-settle delay remains.
- [x] If neither delivers reliable typed input: keep zellij experimental. Not triggered — control is reliable.

#### Remaining command semantics (only after gates 1 and 2 pass)

- [ ] Create a tab named `fm-zellij-smoke` with a controlled working directory.
- [ ] Determine whether `new-tab` returns a tab ID when targeting a detached session.
- [ ] Determine how to get the terminal pane ID for that tab from `list-tabs --json --all`.
- [ ] Confirm Escape delivery with `write --pane-id <id> 27` (the supervision interrupt key).
- [ ] Confirm Ctrl-C delivery if any adapter relies on it.
- [ ] Confirm `dump-screen --pane-id <id>` returns enough viewport/scrollback for stale detection and `fm-peek.sh`.
- [ ] Confirm `close-tab --tab-id <id>` tears down only the target task tab.
- [ ] Confirm commands work both from inside and outside a zellij session (consistent with the gate-1 outcome).

### 3. Make worktree readiness portable

`fm-spawn.sh` currently waits for `treehouse get` by polling tmux `#{pane_current_path}` until the pane cwd changes.

Zellij does not expose an equivalent pane cwd through the already-identified CLI surface.

Replace the tmux-only cwd polling with a multiplexer-neutral readiness probe.

Proposed approach:

1. Create a state file path:

   ```text
   state/<id>.worktree-ready
   ```

2. After sending `treehouse get`, queue a shell command into the same terminal:

   ```sh
   pwd > '<absolute-state-path>'
   ```

3. Poll for that file and read the worktree path from it.

Because terminal input is queued, the `pwd` command should run after `treehouse get` has opened its subshell in the worktree.

Implementation details to verify:

- [ ] Quote the ready-file path safely before sending it through the terminal.
- [ ] Ensure the command runs only after the worktree shell is ready.
- [ ] Keep a timeout equivalent to the current 60 second tmux wait.
- [ ] Delete `state/<id>.worktree-ready` during teardown.
- [ ] Consider switching tmux to the same readiness path to keep spawn behavior identical across backends.

If the probe proves flaky, fallback options are:

- Keep tmux using `pane_current_path` and implement a zellij-only probe with a longer timeout.
- Add a small wrapper script that runs inside the pane after `treehouse get` opens the worktree shell.
- Ask `treehouse` upstream for a non-interactive `get --print-path --command ...` mode, but do not block this change on upstream work.

### 4. Update `bin/fm-spawn.sh`

Refactor `fm-spawn.sh` so it delegates all terminal-surface operations to `fm-mux.sh`.

Tasks:

- [ ] Update the header comment from “tmux window” to “multiplexer tab/window”.
- [ ] Resolve the configured multiplexer before creating a task surface.
- [ ] Create the task surface through `fm-mux.sh create`.
- [ ] Send `treehouse get` through the helper.
- [ ] Use the portable worktree readiness probe from task 3.
- [ ] Keep all harness launch templates unchanged.
- [ ] Keep turn-end hook setup unchanged.
- [ ] Record `mux=` and `target=` in `state/<id>.meta`.
- [ ] Continue recording `window=` for backward compatibility and readable status output.
- [ ] Ensure raw launch command support for verifying new harness adapters still works.
- [ ] Ensure `--scout` behavior is unchanged.

Acceptance criteria:

- [ ] Existing tmux spawn path still creates a task named `fm-<id>` and records compatible metadata.
- [ ] New zellij spawn path creates a zellij tab named `fm-<id>` and records enough target data for send, peek, watch, and teardown.
- [ ] Spawn refuses duplicate task names in the selected backend.

### 5. Update `bin/fm-send.sh`

Refactor `fm-send.sh` so it can send to either backend.

Tasks:

- [ ] Resolve a bare `fm-<id>` by looking up `state/<id>.meta` first when available. Note the prefix: the visible name is `fm-<id>` but the meta file is `state/<id>.meta`, so strip the leading `fm-` before keying on `<id>`. Read `mux=` and `target=` from that meta (defaulting missing `mux=` to tmux and synthesizing `target=tmux:<window>`).
- [ ] Fall back to multiplexer list/resolve when only a visible name is provided and no meta exists.
- [ ] Route literal text to `fm-mux.sh send-text`, forwarding the message as a single argument so quoting/expansion is preserved byte-for-byte (see the input-fidelity requirement in task 1).
- [ ] Route special keys to `fm-mux.sh send-key`.
- [ ] Preserve slash-command delay behavior for codex and other popup-based TUIs.
- [ ] Preserve the existing CLI shape:

  ```sh
  bin/fm-send.sh <window-or-target> <text...>
  bin/fm-send.sh <window-or-target> --key Escape
  ```

Acceptance criteria:

- [ ] Existing tmux usage still works with bare `fm-<id>` and `session:window` targets.
- [ ] Zellij usage works with bare `fm-<id>` after metadata exists.
- [ ] Enter and Escape are delivered correctly in zellij.

### 6. Update `bin/fm-peek.sh`

Refactor `fm-peek.sh` to capture from either backend.

Tasks:

- [ ] Resolve metadata-backed targets the same way as `fm-send.sh`.
- [ ] Route capture to `fm-mux.sh capture`.
- [ ] Preserve the default 40-line bounded output.
- [ ] For zellij, use `dump-screen` output and trim to the requested line count in bash.

Acceptance criteria:

- [ ] Existing tmux peeks are unchanged.
- [ ] Zellij peeks return readable viewport content for the task pane.

### 7. Update `bin/fm-watch.sh`

`fm-watch.sh` is the most important integration point because it treats tmux as the ground truth for stale detection.

Tasks:

- [ ] Replace `tmux list-windows -a ... | grep ':fm-'` with `fm-mux.sh list all`, which unions tmux `:fm-` windows and zellij `fm-` tabs in the scanned sessions (scope defined in task 1). Each entry must carry its backend so the loop captures from the right surface.
- [ ] Replace direct `tmux capture-pane` calls with `fm-mux.sh capture`.
- [ ] Use the full backend-aware target string as the key for `.hash-*`, `.count-*`, and `.stale-*`. The existing `tr ':/.' '___'` keying already normalizes a `zellij:session:tab:pane` target into a safe filename with no change — confirm, don't redesign.
- [ ] Keep the signal scan, check scripts, heartbeat cadence, and busy regex unchanged.
- [ ] Keep the busy-signature match on the last 6 non-blank lines: zellij `dump-screen` returns clean pane content (no zellij chrome), so the footer-region heuristic still locates the harness busy indicator. Verify this against a real harness pane in the spike rather than assuming.
- [ ] Update comments from “pane” and “tmux” where they refer to the backend generally.
- [ ] Keep `FM_BUSY_REGEX` behavior unchanged; zellij changes terminal transport, not harness busy signatures.

Acceptance criteria:

- [ ] With tmux tasks, stale detection behaves as before.
- [ ] With zellij tasks, stale detection hashes the zellij task pane and wakes with a target that `fm-peek.sh` can inspect.
- [ ] Mixed tmux and zellij tasks are either supported or explicitly rejected.

Recommendation: support mixed tasks by reading `mux=` from each task’s metadata and listing both backends.
This is safer for restart recovery because old tmux tasks may exist when the captain switches new tasks to zellij.

### 8. Update `bin/fm-teardown.sh`

Refactor teardown so terminal cleanup is backend-aware.

Tasks:

- [ ] Read `mux=` and `target=` from metadata, defaulting to tmux for old metadata.
- [ ] Keep all git safety checks unchanged.
- [ ] Remove zellij-independent state files as today.
- [ ] Also remove `state/<id>.worktree-ready` if task 3 adds it.
- [ ] Replace `tmux kill-window` with `fm-mux.sh kill`.
- [ ] Keep treehouse return behavior unchanged.
- [ ] Keep fleet sync behavior unchanged.

Acceptance criteria:

- [ ] Teardown refuses unsafe work before touching either multiplexer.
- [ ] Tmux windows are still killed as before.
- [ ] Zellij task tabs are closed without killing unrelated tabs or sessions.

### 9. Update recovery instructions in `AGENTS.md`

Update the firstmate operating instructions to describe multiplexer-neutral recovery.

Tasks:

- [ ] Replace the hard-coded startup command:

  ```sh
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep ':fm-'
  ```

  with a backend-aware command such as:

  ```sh
  bin/fm-mux.sh list all
  ```

- [ ] Replace “tmux is the ground truth” with “the configured multiplexer plus state files are the ground truth”.
- [ ] Update “The tmux window for a task” to “The task surface”.
- [ ] Add `mux=` and `target=` to the documented `state/<id>.meta` fields.
- [ ] Explain that missing `mux=` means legacy tmux.
- [ ] Update spawn, supervise, stale, and teardown wording to say tab/window or task surface.
- [ ] Keep captain-facing etiquette unchanged.

### 10. Update `README.md`

Update the public docs so users understand both multiplexer options.

Tasks:

- [ ] Replace “spawning autonomous agents in tmux windows” with “spawning autonomous agents in tmux windows or zellij tabs”.
- [ ] Update the prerequisite section from “tmux” to “tmux by default, or zellij when configured”.
- [ ] Add a short configuration example:

  ```sh
  mkdir -p config
  printf 'zellij\n' > config/multiplexer
  ```

- [ ] Update “A visible crew” to mention tmux windows and zellij tabs.
- [ ] Update the architecture diagram labels from tmux-only to multiplexer-neutral wording.
- [ ] Update the `bin/` toolbelt descriptions for `fm-spawn.sh`, `fm-send.sh`, `fm-peek.sh`, `fm-watch.sh`, and `fm-teardown.sh`.
- [ ] Add `FM_MULTIPLEXER` only if implementation uses an environment override; otherwise document `config/multiplexer` only.
- [ ] Update development smoke tests to include a zellij smoke test only if it can run reliably in CI/local non-interactive contexts.

### 11. Update script headers and comments

Per `CONTRIBUTING.md`, every helper script has a usage header comment that must stay accurate.

Tasks:

- [ ] Update `bin/fm-bootstrap.sh` header to include zellij detection and config behavior.
- [ ] Update `bin/fm-spawn.sh` header to say multiplexer tab/window instead of tmux window.
- [ ] Update `bin/fm-send.sh` header to say task target instead of tmux window.
- [ ] Update `bin/fm-peek.sh` header to say task pane/surface instead of tmux pane.
- [ ] Update `bin/fm-watch.sh` header to describe backend-aware stale detection.
- [ ] Update `bin/fm-teardown.sh` header to say task surface instead of tmux window.
- [ ] Leave scripts without multiplexer-specific behavior untouched except where examples mention windows.

### 12. Add tests or smoke scripts where practical

This repo currently relies on `shellcheck`, `bash -n`, symlink invariant checks, and manual smoke commands.

Add lightweight tests without introducing heavy dependencies.

Suggested additions:

- [ ] Keep `bash -n bin/*.sh` passing.
- [ ] Keep `shellcheck bin/*.sh` passing.
- [ ] Add `bin/fm-mux.sh --help` and argument validation paths that can be tested without tmux or zellij sessions.
- [ ] Add a documented manual tmux smoke test:

  ```sh
  bin/fm-mux.sh configured
  FM_HEARTBEAT=2 FM_POLL=1 bin/fm-watch.sh
  ```

- [ ] Add a documented manual zellij smoke test guarded by `command -v zellij`.
- [ ] If CI installs zellij, add a non-interactive smoke that creates a temporary zellij session, creates a tab, sends text, captures output, then kills the session.
- [ ] If CI does not install zellij, do not make zellij smoke mandatory in CI.

## Important edge cases

### Existing in-flight tmux tasks

Existing task metadata has `window=` but no `mux=` or `target=`.

All updated scripts must treat this as:

```text
mux=tmux
target=tmux:<window>
```

This prevents a firstmate upgrade from orphaning existing tmux work.

### Mixed backends

A captain might switch `config/multiplexer` while tasks are already in flight.

The safest behavior is:

- Existing tasks use the backend recorded in their metadata.
- New tasks use the current configured backend.
- Watch/recovery list both backends and reconcile by metadata.

If mixed backend support proves too complex, fail explicitly when live tasks exist on a different backend than the configured one.

### Zellij tab and pane IDs

Zellij’s stable routing appears to require tab IDs and pane IDs.

The implementation must not rely only on tab names if zellij allows duplicate names or if commands need pane IDs.

Store the IDs at spawn time and use them for all future actions.

### Worktree readiness

The existing tmux implementation relies on pane cwd introspection.

Zellij support should not depend on cwd introspection unless the spike identifies a reliable zellij equivalent.

The portable ready-file probe is the preferred seam.

### Key delivery

`fm-send.sh --key Escape` is used for real supervision actions.

Zellij key delivery must be verified before claiming support.

At minimum, verify:

- Enter
- Escape
- Ctrl-C, if the existing CLI examples mention it

### Capture fidelity

Watcher stale detection only needs recent visible content and busy signatures near the footer.

Zellij `dump-screen` may not include scrollback unless requested.

Use viewport output for stale detection and bounded peeks unless testing shows full scrollback is necessary.

## Validation plan

### Static validation

Run:

```sh
bash -n bin/*.sh
shellcheck bin/*.sh
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
```

### Tmux regression validation

Run with tmux selected or default:

```sh
rm -f config/multiplexer
bin/fm-bootstrap.sh
FM_HEARTBEAT=2 FM_POLL=1 bin/fm-watch.sh
```

For a full regression, spawn a disposable scout task in a small test project and verify:

- [ ] Spawn creates `fm-<id>` in tmux.
- [ ] `bin/fm-send.sh fm-<id> --key Escape` reaches the pane.
- [ ] `bin/fm-peek.sh fm-<id>` prints output.
- [ ] `bin/fm-watch.sh` can wake on stale state or status files.
- [ ] `bin/fm-teardown.sh <id>` returns the worktree and closes the tmux window.

### Zellij validation

Run with zellij selected:

```sh
mkdir -p config
printf 'zellij\n' > config/multiplexer
bin/fm-bootstrap.sh
```

Then run the zellij spike and a full disposable task validation:

- [ ] Spawn creates a zellij tab named `fm-<id>`.
- [ ] Metadata includes `mux=zellij` and a stable `target=`.
- [ ] `bin/fm-send.sh fm-<id> 'echo zellij-ok'` reaches the tab.
- [ ] `bin/fm-peek.sh fm-<id>` shows `zellij-ok`.
- [ ] `bin/fm-watch.sh` can hash zellij output and wake on stale state.
- [ ] `bin/fm-teardown.sh <id>` closes only the task tab and returns the worktree.

### Documentation validation

Review all changed Markdown for sentence-per-line style.

Check that no docs still imply tmux is the only supported multiplexer unless referring to legacy behavior or defaults.

Suggested search:

```sh
grep -RniE 'tmux|zellij|multiplexer|window|pane|tab' AGENTS.md README.md CONTRIBUTING.md bin .github .agents/skills
```

## Suggested implementation order

1. **Run the gating spike (task 2) first.** Settle gate 1 (detached control) and gate 2 (input fidelity) before any backend code. Their outcome decides whether the build is full zellij support, the inside-zellij-only fallback, or experimental-behind-config. Document the verdict in `fm-mux.sh` comments. Everything below assumes the gates passed.
2. Add `bin/fm-mux.sh` with tmux backend only and migrate existing scripts to it.
3. Validate tmux behavior remains unchanged (the refactor must be a no-op for tmux).
4. Add zellij backend to `bin/fm-mux.sh` using the command forms locked down in step 1.
5. Add portable worktree readiness probing to `fm-spawn.sh`.
6. Update metadata fields and backward-compatible parsing.
7. Update `fm-send.sh`, `fm-peek.sh`, `fm-watch.sh`, and `fm-teardown.sh`.
8. Update bootstrap detection/install hints (conditional `TOOLS` + `install_cmd` zellij arm).
9. Update `AGENTS.md`, `README.md`, and script headers.
10. Run static validation, tmux regression smoke, and zellij smoke.
11. Ship through the normal no-mistakes workflow for this repo.

## Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| ~~Detached zellij session cannot be created/driven via CLI with no client attached.~~ | RESOLVED (spike) | `zellij attach --create-background` yields a fully drivable detached session; verified 2026-06-18. Outside-zellij path is viable; fallback not needed. |
| ~~Input to the harness TUI arrives as a bracketed-paste blob and does not auto-submit.~~ | RESOLVED (spike) | `write-chars` delivers typed input; `send-keys "Enter"` submits (`write 10`/LF does **not** — must be CR). `paste` avoided. Verified against a real claude TUI. |
| Text mangled crossing the new `fm-mux.sh send-text` exec boundary. | High | Forward the payload as a single argument; never re-split or `eval`; round-trip-test a payload with `' " $ \ space`. |
| `fm-mux.sh list` misses zellij tabs because there is no global list primitive. | High | Define scanned-session scope explicitly (current session + `firstmate`); `list all` unions tmux and zellij; document out-of-scope sessions. |
| Worktree readiness probe queues incorrectly. | Medium | Validate with both tmux and zellij; fall back to backend-specific readiness if needed. |
| Existing in-flight tmux tasks become unreachable. | Medium | Default missing `mux=` to tmux and keep `window=` parsing. |
| Watcher stale detection behaves differently with zellij screen dumps. | Medium | Hash only bounded viewport content and keep busy-regex matching on the last nonblank lines; verify against a real harness pane in the spike. |
| Docs leak implementation names into captain-facing instructions. | Low | Keep captain-facing etiquette language unchanged and describe only operator-facing script behavior. |
| CI lacks zellij. | Low | Keep zellij smoke manual unless CI explicitly installs zellij. |

## Non-goals

- Do not replace tmux.
- Do not change harness adapter behavior for claude, codex, opencode, or pi.
- Do not change treehouse pooling semantics.
- Do not change project delivery modes, no-mistakes behavior, or PR/local merge policy.
- Do not make zellij mandatory for existing users.
