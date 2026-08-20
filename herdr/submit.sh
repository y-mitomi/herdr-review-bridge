#!/usr/bin/env bash
# review-bridge: paste a difit-fork "Send to Agent" submission into the
# target coding agent.
#
# Invoked by the forked difit server's POST /api/submit-review handler via
# `herdr plugin action invoke submit`. That handler cannot pass this script
# any payload directly — plugin action invoke carries no env/stdin through to
# the action process — so it drops the payload on disk keyed by its own
# HERDR_PANE_ID, and this script simply processes every pending submission in
# that directory. No focus-based lookup: the herdr-focused pane at click time
# is arbitrary (the user is in a browser window, not a herdr pane), so the
# target agent pane rides inside each payload instead.
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

H="${HERDR_BIN_PATH:-herdr}"

refuse() {
  printf 'review-bridge submit: %s\n' "$1" >&2
  exit 1
}

submit_dir="${TMPDIR:-/tmp}/herdr-review-bridge"

sent=0
failed=0
for submit_file in "$submit_dir"/*-submit.json; do
  [ -f "$submit_file" ] || continue

  payload=$(cat "$submit_file")
  agent_pane_id=$(printf '%s' "$payload" | jq -r '.agentPaneId // empty' 2>/dev/null)
  comments=$(printf '%s' "$payload" | jq -r '.comments // empty' 2>/dev/null)

  if [ -z "$comments" ] || [ -z "$agent_pane_id" ]; then
    printf 'review-bridge submit: skipping malformed submission %s\n' "$submit_file" >&2
    rm -f "$submit_file"
    continue
  fi

  # send-text types the comments into the agent's input box WITHOUT pressing
  # Enter — the user reviews/edits and submits it themselves. (`agent prompt`
  # would fire it off immediately, interrupting whatever the agent is doing.)
  if "$H" pane send-text "$agent_pane_id" "$comments" >/dev/null 2>&1; then
    rm -f "$submit_file"
    # Bring the agent the review was for back into view so the user lands on
    # the conversation their comments were just typed into.
    "$H" agent focus "$agent_pane_id" >/dev/null 2>&1
    printf 'review-bridge: typed review comments into %s\n' "$agent_pane_id"
    sent=$((sent + 1))
  else
    printf 'review-bridge submit: herdr pane send-text failed for pane %s (left %s)\n' \
      "$agent_pane_id" "$submit_file" >&2
    failed=$((failed + 1))
  fi
done

[ "$sent" -gt 0 ] || refuse "no pending submissions delivered (sent=$sent failed=$failed dir=$submit_dir)"
