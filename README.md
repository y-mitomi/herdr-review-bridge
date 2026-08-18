# herdr-review-bridge

A minimal herdr plugin that resolves the focused AI agent pane's git worktree
and branch, then opens a local nvim review session on it.

Pairs with [diffview-review.nvim](https://github.com/y-mitomi/diffview-review.nvim),
but any nvim entrypoint can be wired in via `herdr-plugin.toml`.

## What it does

1. Reads the focused pane's live `foreground_cwd` (falls back to its launch
   cwd when that isn't a git repo) — same resolution order as
   [herdr-reviewr](https://github.com/persiyanov/herdr-reviewr).
2. Resolves that path to a git worktree top level and current branch.
3. Picks a send target: the focused pane if it carries an `agent` field,
   else the first other agent pane in the workspace.
4. Opens a plugin pane running `nvim -c "lua require('diffview_review').open()"`,
   passing `HERDR_REVIEW_WORKTREE`, `HERDR_REVIEW_BRANCH`, and
   `HERDR_REVIEW_AGENT_PANE_ID` as env vars.

## Scope

Resolves only the currently focused pane/agent — no multi-worktree picker.
When several agents or worktrees are active in parallel, whichever one is
focused when the action fires is the one reviewed.

## Install

```
herdr plugin link ~/ghq/github.com/y-mitomi/herdr-review-bridge
```

Bind the `open` action to a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+alt+r"
type = "plugin_action"
command = "y-mitomi.review-bridge.open"
```
