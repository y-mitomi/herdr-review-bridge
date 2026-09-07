# herdr-review-bridge

A herdr plugin that resolves the focused AI agent pane's git worktree,
opens a browser-based diff review for it (via a
[difit](https://github.com/Yuto729/herdr-difit) fork), and pastes
submitted review comments back into the target agent pane.

## What it does

1. Resolves which worktree to review from the **focused pane's** Claude
   Code session — never from other sessions/panes.
2. Opens that worktree in a difit review pane. Default view is
   `origin/<default-branch>...Uncommitted Changes (merge-base)`: the
   whole branch's work since it diverged, plus uncommitted changes.
3. In the browser, add inline comments and press `s` (or the "Send to
   Agent" button) to paste them into the target agent's input box —
   typed only, not submitted; you review and hit enter yourself.

## Worktree resolution

herdr has no read API for "which git worktree is this pane's agent
working in" (`agent list`'s cwd is the OS-level process cwd, which
doesn't move once the agent `cd`s into a worktree internally; herdr's
`pane.report_agent_session` is write-only). So this plugin maintains its
own mapping:

- A Claude Code hook (`herdr/session-hook.sh`, registered under both
  `SessionStart` and `UserPromptSubmit`) records
  `<pane_id>\t<session_id>\t<transcript_path>` into
  `~/.config/herdr/plugins/config/yuto729.review-bridge/sessions.tsv`
  whenever a session starts — or speaks — inside a herdr pane.
- `herdr/open.sh` resolves the pane's session from both that table and
  herdr's own `pane list` `agent_session`, keeps whichever transcript was
  written to more recently, then scans the whole transcript JSONL for
  every distinct `cwd` it touched (newest first). Each resolves to a git
  worktree — all of them are candidates (an agent can legitimately touch
  more than one), but only from *this* session.
- One candidate: opens directly. Two or more: opens an interactive `fzf`
  picker pane (`herdr/pick.sh`).

## Comment submission

The difit fork's server has no way to reach this plugin's action process
with a payload (`plugin action invoke` carries no stdin/env through), so
it writes the payload to `$TMPDIR/herdr-review-bridge/<pane_id>-submit.json`
and invokes the `submit` action, which processes all pending files there
and uses `herdr pane send-text` (types without pressing enter) plus
`herdr agent focus` to bring the target agent pane into view.

## Install

```
herdr plugin link ~/ghq/github.com/Yuto729/herdr-review-bridge
```

Bind the `open` action to a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+alt+r"
type = "plugin_action"
command = "yuto729.review-bridge.open"
```

### Claude Code hooks

Worktree resolution depends on `herdr/session-hook.sh` running as BOTH a
`SessionStart` and a `UserPromptSubmit` hook. SessionStart alone goes
stale: Claude Code fires no SessionStart on `/clear` or on a new
conversation started inside a running process
([anthropics/claude-code#34072](https://github.com/anthropics/claude-code/issues/34072),
[#10373](https://github.com/anthropics/claude-code/issues/10373)), while
UserPromptSubmit fires on every prompt, so the table re-converges as soon
as you speak. Add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash '<path-to-this-repo>/herdr/session-hook.sh'",
            "timeout": 5
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash '<path-to-this-repo>/herdr/session-hook.sh'",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

### difit fork

The "Send to Agent" browser button/`s` keybinding requires the
[herdr-difit fork](https://github.com/Yuto729/herdr-difit) (branch
`herdr-review-integration`), linked globally as `difit` via `npm link`.
Plain upstream `difit` still works for the review view itself, just
without the send-back feature.

## Requirements

- [herdr](https://github.com/persiyanov/herdr) 0.7.5+
- `jq`, `rg` (ripgrep), `fzf` on `PATH`
- Claude Code, with the hooks above installed
