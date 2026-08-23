#!/usr/bin/env bash
# review-bridge: interactive worktree picker. Runs as the "picker" pane
# entrypoint (a real terminal, unlike the non-interactive "open"/"submit"
# actions), so it's the only place in this plugin that can run fzf.
#
# open.sh writes this pane's candidate list to a path keyed by this pane's own
# id (known to open.sh from `plugin pane open`'s response, before this script
# ever starts) since there's no channel to hand this script a payload
# directly. This script re-derives the same path from HERDR_PANE_ID.
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

H="${HERDR_BIN_PATH:-herdr}"
ws="${HERDR_WORKSPACE_ID:-}"
pane="${HERDR_PANE_ID:-}"
plugin_id="${HERDR_PLUGIN_ID:-yuto729.review-bridge}"

fail() {
  printf 'review-bridge picker: %s\n' "$1" >&2
  printf 'Press enter to close.\n'
  read -r _ || true
  [ -n "$pane" ] && "$H" plugin pane close "$pane" >/dev/null 2>&1
  exit 1
}

[ -n "$pane" ] || fail "no HERDR_PANE_ID for this picker pane"

candidates_file="${TMPDIR:-/tmp}/herdr-review-bridge/${pane}-candidates.tsv"
[ -f "$candidates_file" ] || fail "no candidate list at $candidates_file"

if ! command -v fzf >/dev/null 2>&1; then
  fail "fzf is required for the worktree picker but is not on PATH"
fi

# Display column: "<basename>  [<branch>]" — full path kept in the TSV behind
# it so the selection can be mapped back to the exact candidate line.
selected=$(
  awk -F'\t' '{print $1"\t"$2"\t"$3}' "$candidates_file" |
    fzf --delimiter='\t' --with-nth=1,2 \
      --header 'Select a worktree to review (Esc to cancel)' \
      --preview 'echo "worktree: {1}"; echo "branch:   {2}"; echo "agent pane: {3}"' \
      --preview-window=down,3
)

if [ -z "$selected" ]; then
  "$H" plugin pane close "$pane" >/dev/null 2>&1
  rm -f "$candidates_file"
  exit 0
fi

IFS=$'\t' read -r worktree_path branch agent_pane_id <<<"$selected"

# --no-focus for the same reason as in open.sh: the review is read in the
# browser, so the terminal stays on the agent rather than following the pane
# that merely hosts difit. Closing this overlay below returns focus to
# whatever was focused before the picker opened.
open_json=$("$H" plugin pane open --plugin "$plugin_id" --entrypoint pane \
  --placement tab --workspace "$ws" \
  --cwd "$worktree_path" \
  --env "HERDR_REVIEW_WORKTREE=$worktree_path" \
  --env "HERDR_REVIEW_BRANCH=$branch" \
  --env "HERDR_REVIEW_AGENT_PANE_ID=$agent_pane_id" \
  --no-focus 2>/dev/null)
new_pane=$(printf '%s' "$open_json" | jq -r '.result.plugin_pane.pane.pane_id // empty' 2>/dev/null)

rm -f "$candidates_file"
"$H" plugin pane close "$pane" >/dev/null 2>&1

if [ -z "$new_pane" ]; then
  printf 'review-bridge picker: failed to open review pane for %s\n' "$worktree_path" >&2
  exit 1
fi
