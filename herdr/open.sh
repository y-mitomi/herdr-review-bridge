#!/usr/bin/env bash
# review-bridge: resolve the focused agent pane's worktree, then open a local nvim
# review session on it, in a new split pane.
#
# Worktree resolution mirrors herdr-reviewr (specs/herdr-host.md, "Repo discovery"):
# prefer the focused pane's live foreground_cwd; fall back to its launch cwd
# (HERDR_PLUGIN_CONTEXT_JSON.focused_pane_cwd) when the live cwd is not a git repo.
#
# Scope is intentionally narrow: this resolves ONLY the currently focused pane/agent.
# When several agents or worktrees are active in parallel, whichever one is focused
# when this action fires is the one reviewed — no candidate picker.
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

H="${HERDR_BIN_PATH:-herdr}"
ws="${HERDR_WORKSPACE_ID:-}"
pane="${HERDR_PANE_ID:-}"

refuse() {
  printf 'review-bridge: %s\n' "$1" >&2
  exit 1
}

[ -n "$ws" ] || refuse "no workspace context (invoke from inside herdr)"

is_git_repo() { [ -n "$1" ] && git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1; }

launch_cwd=""
[ -n "${HERDR_PLUGIN_CONTEXT_JSON:-}" ] &&
  launch_cwd=$(printf '%s' "$HERDR_PLUGIN_CONTEXT_JSON" | jq -r '.focused_pane_cwd // .workspace_cwd // empty' 2>/dev/null)

focused_pane=$(printf '%s' "${HERDR_PLUGIN_CONTEXT_JSON:-{}}" | jq -r '.focused_pane_id // empty' 2>/dev/null)

panes_json=$("$H" pane list --workspace "$ws" 2>/dev/null) && [ -n "$panes_json" ] &&
  printf '%s' "$panes_json" | jq -e '.result.panes' >/dev/null 2>&1 ||
  refuse "herdr pane list failed for $ws"

live_cwd=""
if [ -n "$focused_pane" ]; then
  live_cwd=$(printf '%s' "$panes_json" |
    jq -r --arg p "$focused_pane" 'first(.result.panes[] | select(.pane_id == $p) | .foreground_cwd // empty)' 2>/dev/null)
fi

if is_git_repo "$live_cwd"; then
  worktree_cwd="$live_cwd"
elif is_git_repo "$launch_cwd"; then
  worktree_cwd="$launch_cwd"
else
  refuse "not a git repo: '${launch_cwd:-<no cwd>}'${live_cwd:+ (live cwd '$live_cwd')}"
fi

worktree_path=$(git -C "$worktree_cwd" rev-parse --show-toplevel 2>/dev/null) ||
  refuse "cannot resolve git top level for '$worktree_cwd'"

branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""

# The focused pane is the send target when it carries an `agent` field; otherwise
# fall back to the sole other agent pane in this workspace (mirrors herdr-reviewr's
# send_target candidacy: an `agent` field, same workspace, not our own pane).
agent_pane_id="$focused_pane"
if [ -n "$agent_pane_id" ]; then
  has_agent=$(printf '%s' "$panes_json" |
    jq -r --arg p "$agent_pane_id" '.result.panes[] | select(.pane_id == $p) | has("agent")' 2>/dev/null)
  [ "$has_agent" = "true" ] || agent_pane_id=""
fi
if [ -z "$agent_pane_id" ]; then
  agents_json=$("$H" agent list 2>/dev/null)
  agent_pane_id=$(printf '%s' "$agents_json" |
    jq -r --arg ws "$ws" --arg me "$pane" \
      'first(.result.agents[] | select(.workspace_id == $ws and .pane_id != $me and .agent) | .pane_id)' 2>/dev/null)
fi

target_pane="${focused_pane:-$pane}"
if [ -z "$target_pane" ]; then
  target_pane=$(printf '%s' "$panes_json" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null)
fi
[ -n "$target_pane" ] || refuse "no pane to attach to in $ws"

open_json=$("$H" plugin pane open --plugin "${HERDR_PLUGIN_ID:-y-mitomi.review-bridge}" --entrypoint pane \
  --placement split --direction right --target-pane "$target_pane" \
  --cwd "$worktree_path" \
  --env "HERDR_REVIEW_WORKTREE=$worktree_path" \
  --env "HERDR_REVIEW_BRANCH=$branch" \
  --env "HERDR_REVIEW_AGENT_PANE_ID=$agent_pane_id" \
  --focus 2>/dev/null)
new_pane=$(printf '%s' "$open_json" | jq -r '.result.plugin_pane.pane.pane_id // empty' 2>/dev/null)
[ -n "$new_pane" ] || refuse "herdr pane open failed"

printf 'opened review for %s (branch %s) in %s\n' "$worktree_path" "${branch:-<detached>}" "$new_pane"
