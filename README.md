# claude-status-bar

A green task progress bar for the [Claude Code](https://claude.com/claude-code) status line.

```
Opus 5 · claude-status-bar · █████░░░░░░░ 40% (2/5 tasks)
```

The bar tracks Claude's todo list — as items are marked complete, it fills. When no todo
list exists for the session, it falls back to context-window usage so the row is never
blank:

```
Opus 5 · claude-status-bar · █████░░░░░░░ 42% context
```

## Why a todo list, not a self-reported percentage

"Percent complete" isn't a quantity the agent actually has. Asking the model to report one
produces a fabricated, non-monotonic number. Todo completion is the only signal available
that reflects real position in a plan, so that's what drives the bar.

**Accept this limitation:** todo items are not equal-sized, so `3/6` does not mean half the
wall-clock work is done. This is a coarse indicator of plan position, not an ETA. See
[DESIGN.md](DESIGN.md) for the full rationale.

## How it works

```
TodoWrite tool call
        │
        ▼
PostToolUse hook  ──writes──▶  /tmp/claude-progress-<session_id>   ("2/5")
                                        │
                                        ▼
                        statusLine script ──prints──▶  status row
                        (also reads context_window from stdin JSON)
```

Two decoupled processes sharing one small file. `todo-progress-hook.py` is the only writer,
`statusline-progress.py` is the only reader, and neither imports the other. State is keyed
on `session_id` so concurrent sessions in different repos don't overwrite each other.

## Install

Requires Python 3 and Claude Code.

```bash
git clone git@github.com:MrProtsyuk/claude-status-bar.git
cd claude-status-bar
cp statusline-progress.py todo-progress-hook.py ~/.claude/
chmod +x ~/.claude/statusline-progress.py ~/.claude/todo-progress-hook.py
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline-progress.py",
    "refreshInterval": 2
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "TodoWrite",
        "hooks": [
          { "type": "command", "command": "~/.claude/todo-progress-hook.py" }
        ]
      }
    ]
  }
}
```

`refreshInterval` is **required, not optional**. The status line otherwise only re-renders
on session start, a new assistant message, `/compact` finishing, a permission-mode change,
or a vim toggle — so without a timer the bar freezes during long agentic turns, which is
exactly when you want to watch it.

Restart Claude Code and accept the workspace trust prompt (`statusLine` runs a shell
command, so it's gated by trust — without it the row stays blank).

## Tradeoffs

- **A custom status line suppresses most footer keyboard hints, including `esc to
  interrupt`.** The keybinding still works; the reminder disappears. This is the main cost
  of using this at all.
- Status line updates debounce at 300ms and an in-flight script is cancelled if a new
  trigger fires, so both scripts stay fast — no git calls, no subprocesses.
- Only stdout is displayed. A non-zero exit or empty output blanks the row.
- The built-in `Tokens Used` line and footer badges are core TUI and are not touched.

## Verifying it works

```bash
# Hook writes state
echo '{"session_id":"t1","tool_name":"TodoWrite","tool_input":{"todos":[
  {"status":"completed"},{"status":"completed"},{"status":"pending"}]}}' \
  | ./todo-progress-hook.py
cat /tmp/claude-progress-t1   # -> 2/3

# Status line renders it
echo '{"session_id":"t1","model":{"display_name":"Opus 5"},
  "workspace":{"current_dir":"/tmp/demo"},
  "context_window":{"used_percentage":42}}' | ./statusline-progress.py

# No state file -> context fallback
echo '{"session_id":"none","model":{"display_name":"Opus 5"},
  "workspace":{"current_dir":"/tmp/demo"},
  "context_window":{"used_percentage":42}}' | ./statusline-progress.py
```

Handled edge cases: missing state file, `used_percentage: null` (before the first API
response and after `/compact`), an empty todo list (no `ZeroDivisionError`), malformed hook
stdin, non-`TodoWrite` tools, and stale `/tmp` files from prior sessions.

The state file is opened with `O_NOFOLLOW` and mode `0600`. `/tmp` is world-writable, so
without that a symlink pre-planted at the state path would make the hook truncate whatever
it points at. `session_id` is a UUID, so this was never practically exploitable — but the
guard costs nothing on a shared host.

**Known gap:** `statusline-progress.py` assumes well-formed JSON on stdin and will exit
non-zero on garbage input, blanking the row until the next refresh. Claude Code always
supplies valid JSON, so this only shows up in manual testing.

## Open questions

- Should the context fallback shift green → yellow → red as context fills, while todo mode
  stays green? Two meanings sharing one widget is a legibility risk.
- Should an `in_progress` todo count as a half-cell, or is that false precision?
- Ship as dotfiles, or package as a Claude Code plugin so `statusLine` and `hooks` install
  together?

## Not planned for v1

Subagent progress rows via `subagentStatusLine`, elapsed-time or cost segments, and
per-project overrides via a repo-root `.claude/settings.json`.
