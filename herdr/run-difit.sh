#!/usr/bin/env bash
# review-bridge: run inside the review pane opened by open.sh. Launches the
# forked difit (https://github.com/y-mitomi/herdr-difit) against the resolved
# worktree's working changes, opens it in the browser, and keeps the pane
# alive so `herdr agent prompt`/submit.sh can still find HERDR_PANE_ID for
# this pane after the browser tab is closed.
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

worktree="${HERDR_REVIEW_WORKTREE:-}"
[ -n "$worktree" ] && [ -d "$worktree" ] || {
  printf 'review-bridge: HERDR_REVIEW_WORKTREE not set or missing: %s\n' "$worktree" >&2
  exec "${SHELL:-bash}"
}

cd "$worktree" || exec "${SHELL:-bash}"

echo "review-bridge: reviewing $worktree (branch ${HERDR_REVIEW_BRANCH:-<detached>})"
echo "review-bridge: target agent pane: ${HERDR_REVIEW_AGENT_PANE_ID:-<none found>}"
echo

# Default view: "origin/main...Uncommitted Changes (merge-base)" — the whole
# branch's work since it diverged from the default branch, uncommitted
# changes included. Resolve the base from origin/HEAD so repos whose default
# branch isn't "main" still work; if there's no usable remote base (no
# remote, detached fresh repo, ...), fall back to plain working changes.
base=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null) # e.g. "origin/main"
if [ -z "$base" ] && git rev-parse --verify origin/main >/dev/null 2>&1; then
  base="origin/main"
fi

# --include-untracked lets difit show untracked files in the diff without an
# interactive "include untracked files?" prompt (which would otherwise block
# forever with no TTY input available in this pane, killing the pane the
# moment difit tries to read stdin). It does this via `git add
# --intent-to-add`, which only records untracked files in the index as empty
# placeholders so `git diff` picks them up — it does not stage their content,
# so a subsequent `git commit` still would not include it. `git status`
# shows them as "A " instead of "??" until something else touches them, but
# that's cosmetic.
if [ -n "$base" ]; then
  # "." = all uncommitted changes ("working" refuses a compare-with target).
  difit . "$base" --merge-base --keep-alive --include-untracked
else
  difit working --keep-alive --include-untracked
fi
status=$?

echo
echo "review-bridge: difit exited ($status). Press enter to close this tab."
exec "${SHELL:-bash}"
