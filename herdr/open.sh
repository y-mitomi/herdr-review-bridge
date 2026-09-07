#!/usr/bin/env bash
# review-bridge: resolve which worktree to review, then open it in a difit
# review pane (herdr/run-difit.sh via the "pane" entrypoint).
#
# The review targets THE FOCUSED PANE's session: pressing the keybinding on
# an agent pane means "review what this agent has been working on", so
# candidates never mix in worktrees from other sessions/panes. Within that
# one session, every distinct worktree seen in its recent transcript window
# is a candidate (an agent can legitimately touch more than one).
#
# - Zero candidates: refuse (nothing to review).
# - One candidate: open it directly, no picker.
# - 2+ candidates: open an overlay picker pane (herdr/pick.sh) that runs fzf
#   interactively and, on selection, opens the review pane itself — an action
#   process like this one has no TTY, so it can't run fzf inline; only a
#   plugin pane (a real terminal) can.
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

H="${HERDR_BIN_PATH:-herdr}"
ws="${HERDR_WORKSPACE_ID:-}"
plugin_id="${HERDR_PLUGIN_ID:-yuto729.review-bridge}"

refuse() {
  printf 'review-bridge: %s\n' "$1" >&2
  exit 1
}

[ -n "$ws" ] || refuse "no workspace context (invoke from inside herdr)"

is_git_repo() { [ -n "$1" ] && git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1; }

# Candidate worktrees come from Claude Code's own transcript, not from any
# herdr API: herdr's `agent list` cwd is the agent process's OS-level cwd,
# which never moves once Claude Code is launched from a fixed parent
# directory and `cd`s internally (this user's normal setup) — useless for
# worktree resolution.
#
# Two sources, and NEITHER is reliably current on its own, so the winner is
# whichever names the more recently written transcript:
#
# - `herdr pane list` (herdr 0.8.0+) exposes each pane's
#   `agent_session.value` — the pane's *interactive* Claude Code session id.
#   It can't be shadowed by nested one-off `claude` invocations
#   (skills/subprocesses) that start their own sessions inside the pane, but
#   it goes stale on /clear or an in-process new conversation: Claude Code
#   fires no SessionStart there (anthropics/claude-code#34072, #10373), so
#   nothing re-reports the new session to herdr.
#
# - session-hook.sh records "<pane_id>\t<session_id>\t<transcript_path>"
#   into sessions_table, registered under BOTH SessionStart and
#   UserPromptSubmit — the latter fires on every prompt, so this table
#   re-converges on the pane's real session as soon as the user speaks after
#   a /clear. Its weakness is the opposite one: nested sessions also fire
#   the hooks, and last-write-wins can briefly point at one of those.
#
# Comparing transcript mtimes picks the live conversation in both failure
# modes: a stale pointer's transcript stopped growing when its session died,
# and a nested one-off's transcript stops growing the moment it exits, while
# the pane's real session keeps writing.
#
# Either way the transcript is the JSONL file named "<session_id>.jsonl"
# under ~/.claude/projects/*/, and every line in it (main chain or subagent
# sidechain alike) carries the *current* cwd at that point in the
# conversation.
#
# bash on macOS defaults to 3.2 (no `mapfile`, no associative arrays), and
# herdr-plugin.toml's `command = ["bash", ...]` resolves whatever bash is on
# PATH — so this stays 3.2-compatible: plain while-read loops and dedup via a
# linear scan of a plain indexed array instead of `declare -A`.
sessions_table="$HOME/.config/herdr/plugins/config/yuto729.review-bridge/sessions.tsv"

focused_pane=$(printf '%s' "${HERDR_PLUGIN_CONTEXT_JSON:-{}}" | jq -r '.focused_pane_id // empty' 2>/dev/null)
[ -n "$focused_pane" ] || refuse "no focused pane in invocation context"

seen_worktrees=()
candidates=() # each entry: "<worktree_path>\t<branch>\t<agent_pane_id>"

already_seen() {
  local needle="$1" w
  for w in "${seen_worktrees[@]:-}"; do
    [ "$w" = "$needle" ] && return 0
  done
  return 1
}

# Candidate 1: the pane's session id as herdr knows it, mapped to its
# transcript by the "<session_id>.jsonl under ~/.claude/projects/*/" naming
# convention (a session id is a uuid, unique across projects).
herdr_transcript=""
session_id=$("$H" pane list 2>/dev/null |
  jq -r --arg p "$focused_pane" \
    '.result.panes[]? | select(.pane_id == $p) | .agent_session.value // empty' 2>/dev/null)
if [ -n "$session_id" ]; then
  for f in "$HOME/.claude/projects"/*/"$session_id".jsonl; do
    [ -f "$f" ] && herdr_transcript="$f" && break
  done
fi

# Candidate 2: the focused pane's most recent hook entry. The recorded path
# is what Claude Code reported at hook time; if the session started in one
# cwd and moved, the file may actually live under a different project dir,
# so fall back to locating it by session id.
hook_transcript=""
if [ -f "$sessions_table" ]; then
  hook_entry=$(awk -F'\t' -v p="$focused_pane" '$1 == p { l = $0 } END { print l }' "$sessions_table")
  if [ -n "$hook_entry" ]; then
    hook_transcript=$(printf '%s' "$hook_entry" | cut -f3)
    if [ ! -f "$hook_transcript" ]; then
      hook_sid=$(printf '%s' "$hook_entry" | cut -f2)
      hook_transcript=""
      for f in "$HOME/.claude/projects"/*/"$hook_sid".jsonl; do
        [ -f "$f" ] && hook_transcript="$f" && break
      done
    fi
  fi
fi

# Newer transcript wins (see the source notes above). `stat -f %m` is
# macOS/BSD, `stat -c %Y` is GNU.
mtime_of() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

transcript_path=""
if [ -n "$herdr_transcript" ] && [ -n "$hook_transcript" ] && [ "$herdr_transcript" != "$hook_transcript" ]; then
  if [ "$(mtime_of "$hook_transcript")" -gt "$(mtime_of "$herdr_transcript")" ]; then
    transcript_path="$hook_transcript"
  else
    transcript_path="$herdr_transcript"
  fi
else
  transcript_path="${herdr_transcript:-$hook_transcript}"
fi
[ -n "$transcript_path" ] || refuse "no session found for focused pane $focused_pane (herdr reports no agent session, and no hook entry in $sessions_table)"
[ -f "$transcript_path" ] || refuse "transcript missing: $transcript_path"

# Every distinct cwd across the whole transcript, newest first (`tac` on
# GNU/Linux, `tail -r` on macOS/BSD where tac doesn't exist; awk keeps the
# first = most recent occurrence). The scan is deliberately unwindowed: most
# lines carry the session's launch cwd, and a worktree the agent cd'd into
# earlier falls out of any small tail window as soon as the conversation moves
# on — which showed up as "opens the wrong directory" / "only one candidate".
# Non-worktree cwds get filtered below, so scanning everything adds no noise.
# All worktrees this one session touched are legitimate candidates — but only
# this session's: worktrees from other panes' sessions never appear.
if command -v tac >/dev/null 2>&1; then
  reverse_lines() { tac "$1"; }
else
  reverse_lines() { tail -r "$1"; }
fi

cwds=$(reverse_lines "$transcript_path" 2>/dev/null |
  rg -o '"cwd":"([^"]*)"' -r '$1' 2>/dev/null | awk '!seen[$0]++')
[ -n "$cwds" ] || refuse "no cwd found in the focused session's transcript"

while IFS= read -r cwd; do
  [ -n "$cwd" ] || continue
  is_git_repo "$cwd" || continue
  worktree_path=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || continue
  already_seen "$worktree_path" && continue
  seen_worktrees+=("$worktree_path")
  branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
  candidates+=("$worktree_path"$'\t'"$branch"$'\t'"$focused_pane")
done <<<"$cwds"

[ "${#candidates[@]}" -gt 0 ] || refuse "the focused session's recent cwds resolved to no git worktree"

# The review happens in the browser, not in this pane — difit opens the tab
# itself — so --no-focus keeps the terminal on the agent the review was
# started from instead of parking it on a pane whose only job is to hold the
# difit process.
open_review_pane() {
  local worktree_path="$1" branch="$2" agent_pane_id="$3"
  local open_json new_pane
  open_json=$("$H" plugin pane open --plugin "$plugin_id" --entrypoint pane \
    --placement tab --workspace "$ws" \
    --cwd "$worktree_path" \
    --env "HERDR_REVIEW_WORKTREE=$worktree_path" \
    --env "HERDR_REVIEW_BRANCH=$branch" \
    --env "HERDR_REVIEW_AGENT_PANE_ID=$agent_pane_id" \
    --no-focus 2>/dev/null)
  new_pane=$(printf '%s' "$open_json" | jq -r '.result.plugin_pane.pane.pane_id // empty' 2>/dev/null)
  [ -n "$new_pane" ] || refuse "herdr pane open failed"
  printf 'opened review for %s (branch %s) in %s\n' "$worktree_path" "${branch:-<detached>}" "$new_pane"
}

if [ "${#candidates[@]}" -eq 1 ]; then
  IFS=$'\t' read -r worktree_path branch agent_pane_id <<<"${candidates[0]}"
  open_review_pane "$worktree_path" "$branch" "$agent_pane_id"
  exit 0
fi

# 2+ candidates: hand off to the interactive picker pane. Encode candidates as
# TSV on disk, then name the file to pick.sh with --env.
#
# The file has to exist before the pane is opened: `plugin pane open` starts
# the pane's process immediately, so pick.sh is already reading by the time
# the response (and any pane id derived from it) reaches us. Keying the path
# on that pane id lost the race and pick.sh reported "no candidate list".
picker_dir="${TMPDIR:-/tmp}/herdr-review-bridge"
mkdir -p "$picker_dir"

candidates_file=$(mktemp "$picker_dir/candidates.XXXXXX") || refuse "could not create candidate list"
printf '%s\n' "${candidates[@]}" >"$candidates_file"

open_json=$("$H" plugin pane open --plugin "$plugin_id" --entrypoint picker \
  --placement overlay \
  --env "HERDR_REVIEW_CANDIDATES=$candidates_file" \
  --focus 2>/dev/null)
picker_pane=$(printf '%s' "$open_json" | jq -r '.result.plugin_pane.pane.pane_id // empty' 2>/dev/null)
if [ -z "$picker_pane" ]; then
  rm -f "$candidates_file"
  refuse "herdr pane open (picker) failed"
fi

printf 'opened worktree picker in %s (%d candidates)\n' "$picker_pane" "${#candidates[@]}"
