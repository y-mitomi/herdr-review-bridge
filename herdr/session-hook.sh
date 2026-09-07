#!/usr/bin/env bash
# review-bridge: Claude Code SessionStart hook. Records "this pane is running
# this Claude Code session, whose transcript lives at this path" so open.sh
# can later resolve "which pane does this worktree's most recent session
# belong to" without depending on any herdr API (herdr's own
# pane.report_agent_session is write-only — there is no CLI/socket read path
# for it, so this plugin keeps its own table instead of relying on herdr to
# remember anything).
#
# Registered directly in ~/.claude/settings.json by the user (not by `herdr
# integration install claude`, which was tried and reverted — same idea, but
# this table is ours to read, not locked inside herdr), under BOTH
# hooks.SessionStart and hooks.UserPromptSubmit. SessionStart alone is not
# enough: Claude Code does not fire it on /clear or on a new conversation
# started inside a running process (anthropics/claude-code#34072, #10373),
# so a pane's entry went stale as soon as the user cleared — herdr's own
# agent_session goes equally stale, and open.sh then reviewed a long-dead
# session's worktree. UserPromptSubmit fires on every prompt and carries the
# same session_id/transcript_path fields, so the table re-converges on the
# pane's real session the moment the user speaks in it.
set -uo pipefail

pane_id="${HERDR_PANE_ID:-}"
[ -n "$pane_id" ] || exit 0

hook_input=$(cat)

session_id=$(printf '%s' "$hook_input" | jq -r '.session_id // empty' 2>/dev/null)
transcript_path=$(printf '%s' "$hook_input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$session_id" ] && [ -n "$transcript_path" ] || exit 0

table_dir="$HOME/.config/herdr/plugins/config/yuto729.review-bridge"
mkdir -p "$table_dir" 2>/dev/null || exit 0
table_file="$table_dir/sessions.tsv"

# Append-only; readers take the last line per pane_id (a pane's most recent
# entry wins over any earlier session that used to run there). UserPromptSubmit
# fires on every prompt, so skip the append when the pane's latest entry is
# already this exact session — the table stays proportional to session
# switches, not to conversation length.
entry=$(printf '%s\t%s\t%s' "$pane_id" "$session_id" "$transcript_path")
last=$(awk -F'\t' -v p="$pane_id" '$1 == p { l = $0 } END { print l }' "$table_file" 2>/dev/null)
[ "$last" = "$entry" ] && exit 0
printf '%s\n' "$entry" >>"$table_file"
