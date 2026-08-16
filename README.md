# claude-status-bar

A green task progress bar for the [Claude Code](https://claude.com/claude-code) status line.

```
Opus 5 · claude-status-bar · █████░░░░░░░ 40% (2/5 tasks) · 31% ctx
esc to interrupt · ? for shortcuts
```

The bar is **per turn**: it starts at 0% when you send a prompt and reaches 100% when the
turn ends. In between it prefers Claude's todo list — as items are marked complete, it
fills. On a turn with no todo list it shows an estimate instead, so the row is never
blank:

```
Opus 5 · claude-status-bar · ██████░░░░░░ 48% (est.) · 31% ctx
esc to interrupt · ? for shortcuts
```

Context-window usage rides along as dim trailing text. It isn't task progress and doesn't
drive the bar.

The second row carries the keyboard hints that Claude Code stops drawing once a custom
status line exists — see [Restoring the footer hints](#restoring-the-footer-hints).

## What drives the bar

| Signal | When it's used | Honest? |
|---|---|---|
| Todo list (`completed / total`) | Whenever the turn has one | Measured |
| Tool calls, through a saturating curve | Turns without a todo list | **Estimate** |
| Context-window usage | Never — dim text only | Measures context, not work |
| Model self-reporting a percentage | Never | Fabricated, non-monotonic |

"Percent complete" isn't a quantity the agent actually has. Todo completion is the only
signal that reflects real position in a plan, so it wins whenever it exists.

The fallback estimate is `95·n/(n+6)` over tool calls `n`. Two properties keep it from
lying in the way that would matter:

- **Monotonic** — `n` only increases within a turn, so the bar never jumps backward.
- **Asymptotic** — bounded below 95 for any finite `n`, so it *cannot* reach 100% on its
  own. Only the end of the turn completes the bar. It will never sit at 100% while
  Claude is still working.

It's still an estimate: `n` counts tool calls, not work, so one slow call reads lower
than ten fast ones. That's why it's labeled `(est.)`.

**Accept this limitation:** todo items are not equal-sized either, so `3/6` does not mean
half the wall-clock work is done. This is a coarse indicator of plan position, not an
ETA. See [DESIGN.md](DESIGN.md) for the full rationale.

## How it works

```
any tool call ──PostToolUse──▶  /tmp/claude-activity-<session_id>  (size = call count)
   └── if TodoWrite ──────────▶  /tmp/claude-progress-<session_id>  ("2/5")

UserPromptSubmit ──raises────▶  /tmp/claude-busy-<session_id>
                 └─ and empties activity, deletes progress  → bar restarts at 0%
Stop / StopFailure ──lowers──▶  the busy flag, leaving activity → bar reads 100%
                                             │
                                             ▼
                             statusline-progress.py ──prints──▶  two rows
```

Decoupled processes sharing three small files. The hooks are the only writers, the status
line is the only reader, and neither imports the other. State is keyed on `session_id` so
concurrent sessions in different repos don't overwrite each other.

The activity counter is a file whose **size** is the count — each tool call appends one
byte. `O_APPEND` writes can't interleave, so overlapping tool calls each get counted,
where a read-modify-write integer would lose increments.

## Install

Requires Python 3 and Claude Code.

```bash
git clone git@github.com:MrProtsyuk/claude-status-bar.git
cd claude-status-bar
cp statusline-progress.py todo-progress-hook.py turn-state-hook.py ~/.claude/
chmod +x ~/.claude/statusline-progress.py ~/.claude/todo-progress-hook.py \
         ~/.claude/turn-state-hook.py
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
      { "hooks": [{ "type": "command", "command": "~/.claude/todo-progress-hook.py" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "~/.claude/turn-state-hook.py" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/turn-state-hook.py" }] }
    ],
    "StopFailure": [
      { "hooks": [{ "type": "command", "command": "~/.claude/turn-state-hook.py" }] }
    ]
  }
}
```

Note the `PostToolUse` entry has **no matcher** — it runs on every tool call, because
that's the activity counter. It costs one short-lived Python process per tool call.

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
`turn-state-hook.py` supplies the missing state:

| Event | Effect |
|---|---|
| `UserPromptSubmit` | Creates `/tmp/claude-busy-<session_id>`; resets the bar to 0% |
| `Stop`, `StopFailure` | Deletes it; the bar completes at 100% |

Existence is the flag; there are no contents to parse. The hint row shows `esc to
interrupt` only while it is up.

**Known unresolved edge case:** `Stop` is documented as firing when Claude finishes
responding and `StopFailure` when a turn ends from an API error. Neither is documented as
firing when *you* interrupt with `esc`. If neither does, the flag stays up until your next
prompt — the hint is wrong for that window, and the bar stays frozen mid-estimate instead
of completing. To check, interrupt a turn and watch the row. If it doesn't fall back to
`? for shortcuts`, the hook needs another event. A staleness timeout would be the wrong
fix, since it would misreport long legitimate turns.

`hold space to speak` is deliberately omitted: nothing on stdin reports whether dictation
is available, so it would be a guess.

## Tradeoffs

- Status line updates debounce at 300ms and an in-flight script is cancelled if a new
  trigger fires, so both scripts stay fast — no git calls, no subprocesses.
- Only stdout is displayed. A non-zero exit or empty output blanks the row.
- The `PostToolUse` hook now runs on every tool call, not just `TodoWrite`.
- The built-in `Tokens Used` line and footer badges are core TUI and are not touched.

## Verifying it works

```bash
./test.sh
```

49 assertions, no dependencies beyond bash and Python 3. Covers every case in DESIGN.md
section 8 that can be checked without a live session: the full turn lifecycle (reset on
prompt, the curve at 1/6/20 calls, completion on `Stop`), that the estimate never
decreases and never reaches 100% while busy, todo ratio outranking the estimate, missing
state files, `used_percentage: null` (before the first API response and after `/compact`),
an empty todo list (no `ZeroDivisionError`), malformed hook stdin, both hint states, and
the symlink guards.

Two things it can't cover, because they need a real session: that the bar keeps advancing
during a long turn (`refreshInterval`), and what `esc` does to the busy flag.

All three state files are opened with `O_NOFOLLOW` and mode `0600`, and the reader uses
`lstat` rather than `stat`. `/tmp` is world-writable, so without that a symlink
pre-planted at any path would make a hook truncate whatever it points at. `session_id` is
a UUID, so this was never practically exploitable — but the guard costs nothing on a
shared host.

**Known gap:** `statusline-progress.py` assumes well-formed JSON on stdin and will exit
non-zero on garbage input, blanking the row until the next refresh. Claude Code always
supplies valid JSON, so this only shows up in manual testing.

## Open questions

- Should the bar shift green → yellow → red as the estimate climbs, while todo mode stays
  green? Two meanings sharing one widget is a legibility risk.
- Should an `in_progress` todo count as a half-cell, or is that false precision?
- Is `95·n/(n+6)` tuned right? `HALFWAY = 6` assumes a typical turn is a handful of tool
  calls; a habitually longer workflow would want a larger constant.
- Ship as dotfiles, or package as a Claude Code plugin so `statusLine` and `hooks` install
  together?

## Not planned for v1

Subagent progress rows via `subagentStatusLine`, elapsed-time or cost segments, and
per-project overrides via a repo-root `.claude/settings.json`.
