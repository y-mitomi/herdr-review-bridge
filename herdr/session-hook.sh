#!/usr/bin/env bash
# review-bridge: Claude Code SessionStart hook. Records "this pane is running
# this Claude Code session, whose transcript lives at this path" so open.sh
# can later resolve "which pane does this worktree's most recent session
# belong to" without depending on any herdr API (herdr's own
# pane.report_agent_session is write-only — there is no CLI/socket read path
# for it, so this plugin keeps its own table instead of relying on herdr to
# remember anything).
#
# Registered directly in ~/.claude/settings.json's hooks.SessionStart by the
# user (not by `herdr integration install claude`, which was tried and
# reverted — same idea, but this table is ours to read, not locked inside
# herdr).
set -uo pipefail

pane_id="${HERDR_PANE_ID:-}"
[ -n "$pane_id" ] || exit 0

hook_input=$(cat)

session_id=$(printf '%s' "$hook_input" | jq -r '.session_id // empty' 2>/dev/null)
transcript_path=$(printf '%s' "$hook_input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$session_id" ] && [ -n "$transcript_path" ] || exit 0

table_dir="$HOME/.config/herdr/plugins/config/y-mitomi.review-bridge"
mkdir -p "$table_dir" 2>/dev/null || exit 0
table_file="$table_dir/sessions.tsv"

# Append-only; readers take the last line per pane_id (a pane's most recent
# SessionStart wins over any earlier session that used to run there).
printf '%s\t%s\t%s\n' "$pane_id" "$session_id" "$transcript_path" >>"$table_file"
