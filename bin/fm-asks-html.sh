#!/usr/bin/env bash
# Render data/captain-asks.md and data/backlog.md into a single self-contained
# HTML operator view at state/captain-view.html: open asks up top grouped by
# type, backlog by status, resolved asks collapsed at the bottom. Inline CSS,
# no network deps, so the file opens anywhere. The output lives under the
# gitignored state/ dir - the script is tracked, its artifact is per-fleet
# local state. fm-captain-asks.sh regenerates it after every mutating verb;
# run this by hand after editing data/backlog.md.
# Usage:
#   fm-asks-html.sh          # render (prints the output path)
#   fm-asks-html.sh path     # print the output path without rendering
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ASKS="$DATA/captain-asks.md"
BACKLOG="$DATA/backlog.md"
OUT="$STATE/captain-view.html"

case "${1:-}" in
  path) printf '%s\n' "$OUT"; exit 0 ;;
  "") ;;
  *) echo "usage: fm-asks-html.sh [path]" >&2; exit 1 ;;
esac

# Every fragment renderer shares these awk helpers: HTML-escape first, then
# turn https URLs into anchors (escaped text keeps URLs intact because '&'
# has already become '&amp;', which is valid in an href).
AWK_HELPERS='
function esc(s) {
  gsub(/&/, "\\&amp;", s)
  gsub(/</, "\\&lt;", s)
  gsub(/>/, "\\&gt;", s)
  return s
}
function linkify(s,   out, url) {
  out = ""
  while (match(s, /https?:\/\/[^[:space:]<>)"\047]+/)) {
    url = substr(s, RSTART, RLENGTH)
    out = out substr(s, 1, RSTART - 1) "<a href=\"" url "\">" url "</a>"
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
'

# render_asks <open|resolved>: emit the ask list for one section of
# data/captain-asks.md. Structured lines are
#   - [ ] <date> | <id> | <type> | <summary> [| source: <text>] <!-- fm-ask:... -->
# with resolve appending " (resolved <date>[: note])" before the comment.
# Anything else under the section renders as a free-form item so hand-added
# bullets still show up. Open asks are grouped by type, urgent first.
render_asks() {
  local want=$1
  [ -f "$ASKS" ] || { printf '<p class="empty">No ledger yet - nothing recorded.</p>\n'; return 0; }
  awk -v want="$want" "$AWK_HELPERS"'
    BEGIN { ngroups = split("blocker failure decision merge local-merge credential other", gorder, " ") }
    /^## Open$/     { sec = "open"; next }
    /^## Resolved$/ { sec = "resolved"; next }
    /^## /          { sec = ""; next }
    sec != want || !/^- / { next }
    {
      line = $0
      sub(/[[:space:]]*<!-- fm-ask:[^>]*-->[[:space:]]*$/, "", line)
      resolved = ""
      ri = index(line, " (resolved ")
      if (ri > 0) {
        resolved = substr(line, ri + 2)
        sub(/\)[[:space:]]*$/, "", resolved)
        line = substr(line, 1, ri - 1)
      }
      structured = sub(/^- \[[ xX]\] /, "", line)
      if (!structured) sub(/^- /, "", line)
      n = split(line, f, / \| /)
      if (structured && n >= 4) {
        date = f[1]; id = f[2]; type = f[3]
        summary = ""; source = ""
        for (i = 4; i <= n; i++) {
          if (f[i] ~ /^source: /) source = substr(f[i], 9)
          else summary = (summary == "" ? f[i] : summary " | " f[i])
        }
      } else {
        date = ""; id = ""; type = "note"; summary = line; source = ""
      }
      key = type
      if (key !~ /^(blocker|failure|decision|merge|local-merge|credential)$/) key = "other"
      item = "<li class=\"ask ask-" key "\">"
      item = item "<div class=\"ask-head\"><span class=\"badge badge-" key "\">" esc(type) "</span>"
      if (id != "") item = item "<span class=\"ask-id\">" esc(id) "</span>"
      if (date != "") item = item "<span class=\"ask-date\">" esc(date) "</span>"
      item = item "</div><div class=\"ask-summary\">" linkify(esc(summary)) "</div>"
      if (source != "") item = item "<div class=\"ask-note\">source: " linkify(esc(source)) "</div>"
      if (resolved != "") item = item "<div class=\"ask-note ask-resolved\">" linkify(esc(resolved)) "</div>"
      item = item "</li>"
      items[key] = items[key] item "\n"
      total++
    }
    END {
      if (total == 0) {
        if (want == "open") print "<p class=\"empty\">No open asks - nothing is waiting on the captain.</p>"
        else print "<p class=\"empty\">No resolved asks yet.</p>"
        exit
      }
      print "<ul class=\"asks\">"
      for (g = 1; g <= ngroups; g++) if (items[gorder[g]] != "") printf "%s", items[gorder[g]]
      print "</ul>"
    }
  ' "$ASKS"
}

# render_backlog <In flight|Queued|Done>: emit the task list for one section
# of data/backlog.md. Handles the checkbox forms and the bold in-flight
# `- **<id>**` form; a trailing parenthetical (repo/since, merged, reported)
# renders as muted metadata and blocked-by items are flagged.
render_backlog() {
  local want=$1
  [ -f "$BACKLOG" ] || { printf '<p class="empty">No backlog file yet.</p>\n'; return 0; }
  awk -v want="$want" "$AWK_HELPERS"'
    /^## In flight$/ { sec = "In flight"; next }
    /^## Queued$/    { sec = "Queued"; next }
    /^## Done$/      { sec = "Done"; next }
    /^## /           { sec = ""; next }
    sec != want || !/^- / { next }
    {
      line = $0
      if (!sub(/^- \[[ xX]\] /, "", line)) sub(/^- /, "", line)
      id = ""
      if (match(line, /^\*\*[^*]+\*\*/)) {
        id = substr(line, 3, RLENGTH - 4)
        line = substr(line, RLENGTH + 1)
      } else if (match(line, /^[^[:space:]]+/)) {
        id = substr(line, 1, RLENGTH)
        line = substr(line, RLENGTH + 1)
      }
      sub(/^[[:space:]]*-[[:space:]]+/, "", line)
      meta = ""
      if (match(line, /\([^()]*\)[[:space:]]*$/)) {
        meta = substr(line, RSTART + 1)
        sub(/\)[[:space:]]*$/, "", meta)
        line = substr(line, 1, RSTART - 1)
      }
      cls = "task"
      if (index(line, "blocked-by:") > 0) cls = cls " task-blocked"
      item = "<li class=\"" cls "\"><span class=\"task-id\">" esc(id) "</span>"
      item = item "<span class=\"task-text\">" linkify(esc(line)) "</span>"
      if (meta != "") item = item "<span class=\"task-meta\">" esc(meta) "</span>"
      item = item "</li>"
      body = body item "\n"
      total++
    }
    END {
      if (total == 0) {
        if (want == "In flight") print "<p class=\"empty\">Nothing in flight.</p>"
        else if (want == "Queued") print "<p class=\"empty\">Queue is empty.</p>"
        else print "<p class=\"empty\">No completed work recorded.</p>"
        exit
      }
      print "<ul class=\"tasks\">"
      printf "%s", body
      print "</ul>"
    }
  ' "$BACKLOG"
}

# count_items <file> <section>: number of `- ` bullets under one `## <section>`
# heading, for the header chips. Missing file counts as zero.
count_items() {
  local file=$1 want=$2
  [ -f "$file" ] || { echo 0; return 0; }
  awk -v want="$want" '
    $0 == "## " want { sec = 1; next }
    /^## / { sec = 0; next }
    sec && /^- / { n++ }
    END { print n + 0 }
  ' "$file"
}

open_count=$(count_items "$ASKS" "Open")
inflight_count=$(count_items "$BACKLOG" "In flight")
queued_count=$(count_items "$BACKLOG" "Queued")
generated=$(date '+%Y-%m-%d %H:%M:%S %Z')

open_chip_class="chip"
[ "$open_count" -gt 0 ] && open_chip_class="chip chip-alert"

mkdir -p "$STATE"
tmp=$(mktemp "$STATE/.captain-view.XXXXXX")
trap 'rm -f "$tmp"' EXIT

{
  cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Captain's view</title>
<style>
  :root { color-scheme: light; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 2rem 1rem 4rem;
    background: #f6f7f9; color: #1f2937;
    font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }
  main { max-width: 920px; margin: 0 auto; }
  h1 { font-size: 1.4rem; margin: 0 0 0.25rem; }
  h2 { font-size: 1.05rem; margin: 2rem 0 0.75rem; color: #374151; }
  .generated { color: #6b7280; font-size: 0.85rem; margin: 0 0 1rem; }
  .chips { display: flex; gap: 0.5rem; flex-wrap: wrap; margin: 0 0 0.5rem; }
  .chip {
    background: #e5e7eb; color: #374151; border-radius: 999px;
    padding: 0.15rem 0.7rem; font-size: 0.85rem;
  }
  .chip-alert { background: #fee2e2; color: #b91c1c; font-weight: 600; }
  ul.asks, ul.tasks { list-style: none; margin: 0; padding: 0; }
  .ask, .task {
    background: #fff; border: 1px solid #e5e7eb; border-left-width: 4px;
    border-radius: 8px; padding: 0.65rem 0.9rem; margin: 0 0 0.6rem;
  }
  .ask-blocker, .ask-failure { border-left-color: #dc2626; }
  .ask-decision { border-left-color: #d97706; }
  .ask-merge, .ask-local-merge { border-left-color: #2563eb; }
  .ask-credential { border-left-color: #7c3aed; }
  .ask-other { border-left-color: #9ca3af; }
  .ask-head { display: flex; gap: 0.6rem; align-items: baseline; flex-wrap: wrap; margin-bottom: 0.25rem; }
  .badge {
    border-radius: 4px; padding: 0.05rem 0.45rem;
    font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.03em;
  }
  .badge-blocker, .badge-failure { background: #fee2e2; color: #b91c1c; }
  .badge-decision { background: #fef3c7; color: #b45309; }
  .badge-merge, .badge-local-merge { background: #dbeafe; color: #1d4ed8; }
  .badge-credential { background: #ede9fe; color: #6d28d9; }
  .badge-other { background: #e5e7eb; color: #4b5563; }
  .ask-id, .task-id { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.85rem; color: #4b5563; }
  .ask-date, .task-meta { color: #9ca3af; font-size: 0.8rem; }
  .ask-summary { overflow-wrap: anywhere; }
  .ask-note { color: #6b7280; font-size: 0.85rem; margin-top: 0.3rem; overflow-wrap: anywhere; }
  .ask-resolved { color: #15803d; }
  .task { display: flex; gap: 0.6rem; align-items: baseline; flex-wrap: wrap; border-left-color: #d1d5db; }
  .task-text { flex: 1 1 24rem; overflow-wrap: anywhere; }
  .task-blocked { border-left-color: #d97706; background: #fffbeb; }
  .empty { color: #6b7280; font-style: italic; background: #fff; border: 1px dashed #d1d5db; border-radius: 8px; padding: 0.65rem 0.9rem; }
  a { color: #2563eb; word-break: break-all; }
  details { margin-top: 2rem; }
  details summary { cursor: pointer; font-size: 1.05rem; font-weight: 600; color: #374151; margin-bottom: 0.75rem; }
  details .ask { opacity: 0.85; }
</style>
</head>
<body>
<main>
<h1>Captain's view</h1>
<p class="generated">Generated $generated - refresh with <code>bin/fm-asks-html.sh</code></p>
<div class="chips">
  <span class="$open_chip_class">$open_count open ask(s)</span>
  <span class="chip">$inflight_count in flight</span>
  <span class="chip">$queued_count queued</span>
</div>
<h2>Open asks</h2>
EOF
  render_asks open
  cat <<'EOF'
<h2>In flight</h2>
EOF
  render_backlog "In flight"
  cat <<'EOF'
<h2>Queued</h2>
EOF
  render_backlog "Queued"
  cat <<'EOF'
<h2>Done</h2>
EOF
  render_backlog "Done"
  cat <<'EOF'
<details>
<summary>Resolved asks</summary>
EOF
  render_asks resolved
  cat <<'EOF'
</details>
</main>
</body>
</html>
EOF
} > "$tmp"

mv "$tmp" "$OUT"
trap - EXIT
printf '%s\n' "$OUT"
