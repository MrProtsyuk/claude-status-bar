# claude-status-bar

A green task progress bar for the [Claude Code](https://claude.com/claude-code) status line.

```
Opus 5 · claude-status-bar · █████░░░░░░░ 40% (2/5 tasks)
esc to interrupt · ? for shortcuts
```

The bar tracks Claude's todo list — as items are marked complete, it fills. When no todo
list exists for the session, it falls back to context-window usage so the row is never
blank:

```
Opus 5 · claude-status-bar · █████░░░░░░░ 42% context
? for shortcuts
```

The second row carries the keyboard hints that Claude Code stops drawing once a custom
status line exists — see [Restoring the footer hints](#restoring-the-footer-hints).

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
cp statusline-progress.py todo-progress-hook.py busy-state-hook.py ~/.claude/
chmod +x ~/.claude/statusline-progress.py ~/.claude/todo-progress-hook.py \
         ~/.claude/busy-state-hook.py
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
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "~/.claude/busy-state-hook.py" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/busy-state-hook.py" }] }
    ],
    "StopFailure": [
      { "hooks": [{ "type": "command", "command": "~/.claude/busy-state-hook.py" }] }
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

## Restoring the footer hints

Configuring any custom status line makes Claude Code stop drawing most of the footer's
keyboard hints, including `esc to interrupt`, the `? for shortcuts` fallback, and the
`hold space to speak` dictation hint. **There is no setting to keep them** — the full list
of `statusLine` options is `type`, `command`, `padding`, `refreshInterval`, and
`hideVimModeIndicator`. The keybindings themselves never stop working; you lose the
reminder, not the function.

So this project redraws the two hints worth having on its own second row. The catch is
that nothing in the status line's stdin says whether Claude is currently working, so a
hardcoded `esc to interrupt` would sit there lying every time the session went idle.
`busy-state-hook.py` supplies the missing state:

| Event | Effect |
|---|---|
| `UserPromptSubmit` | Creates `/tmp/claude-busy-<session_id>` |
| `Stop`, `StopFailure` | Deletes it |

Existence is the flag; there are no contents to parse. The hint row shows `esc to
interrupt` only while it is up.

**Known unresolved edge case:** `Stop` is documented as firing when Claude finishes
responding and `StopFailure` when a turn ends from an API error. Neither is documented as
firing when *you* interrupt with `esc`. If neither does, the flag stays up until your next
prompt and the hint is wrong for that window. To check, interrupt a turn and watch the
row — if it doesn't fall back to `? for shortcuts`, the hook needs another event. A
staleness timeout would be the wrong fix, since it would misreport long legitimate turns.

`hold space to speak` is deliberately omitted: nothing on stdin reports whether dictation
is available, so it would be a guess.

## Tradeoffs

- Status line updates debounce at 300ms and an in-flight script is cancelled if a new
  trigger fires, so both scripts stay fast — no git calls, no subprocesses.
- Only stdout is displayed. A non-zero exit or empty output blanks the row.
- The built-in `Tokens Used` line and footer badges are core TUI and are not touched.

## Verifying it works

```bash
./test.sh
```

26 assertions, no dependencies beyond bash and Python 3. Covers every case in DESIGN.md
section 8 that can be checked without a live session: missing state file,
`used_percentage: null` (before the first API response and after `/compact`), an empty
todo list (no `ZeroDivisionError`), malformed hook stdin, non-`TodoWrite` tools, both hint
states, each busy-flag event, and the symlink guards.

Two things it can't cover, because they need a real session: that the bar keeps advancing
during a long turn (`refreshInterval`), and what `esc` does to the busy flag.

Both state files are opened with `O_NOFOLLOW` and mode `0600`, and the reader uses `lstat`
rather than `stat`. `/tmp` is world-writable, so without that a symlink pre-planted at
either path would make a hook truncate whatever it points at. `session_id` is a UUID, so
this was never practically exploitable — but the guard costs nothing on a shared host.

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
