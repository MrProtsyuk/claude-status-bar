# Design: Task Progress Bar for Claude Code

**Status:** Draft — ready to implement
**Owner:** Mark
**Target:** `~/.claude/` (user-level config), portable to a plugin later

---

## 1. Goal

Show a green progress bar with a percentage in the Claude Code terminal UI, reflecting
how far along Claude is in the task it is currently working on.

## 2. Non-goals

- Modifying the built-in `Tokens Used` / spinner line. That is core UI inside the
  bundled npm package and is not an extension point.
- Replacing the footer badges.
- Any network calls, telemetry, or persistence beyond a scratch file in `/tmp`.

## 3. Constraints (verified against Claude Code docs)

| Constraint | Consequence for design |
|---|---|
| Core TUI is not modifiable | Use the `statusLine` setting, which renders its own row above the footer badges |
| A custom status line suppresses most footer keyboard hints, including `esc to interrupt` | Not accepted — re-rendered on a second status line row (§6.3). There is no setting to keep the built-in hints |
| Status line re-runs only on: session start, new assistant message, `/compact` finish, permission-mode change, vim toggle, or `refreshInterval` timer | `refreshInterval` is **required**, or the bar freezes during long agentic turns |
| Updates debounce at 300ms; an in-flight script is cancelled if a new trigger fires | Script must be fast — no git calls, no subprocesses |
| Only stdout is displayed; non-zero exit or empty output blanks the status line | Never raise. Each `print` is one row; we print exactly two |
| `statusLine` executes a shell command, so it is gated by workspace trust | Trust dialog must be accepted or the row stays blank |

## 4. Key design decision: what is the denominator?

"Percent complete" is not a quantity the agent has. Four candidate signals:

| Source | Real task progress? | Verdict |
|---|---|---|
| Todo list (`completed / total` from `TodoWrite`) | Yes | **Primary** |
| Tool calls this turn, through a saturating curve | No — an estimate | **Fallback** |
| `context_window.used_percentage` | No — measures context fill, not work done | Demoted to trailing text |
| Model self-reporting a percentage | No — fabricated, non-monotonic | Rejected |

**Requirement driving this:** the bar must start at 0% on each prompt and reach 100% as
that prompt completes. Context usage cannot do that — it is cumulative across the
session and unrelated to the current task — so it moved out of the bar and became a dim
suffix. A turn with a todo list gets the measured ratio. A turn without one has no
completion signal at all, and the choice was to show an estimate rather than nothing.

**The estimate is an estimate, and the design says so.** `pct = 95·n/(n+6)` over tool
calls `n`. Two properties make it safe to show:

- **Monotonic.** `n` only ever increases within a turn, so the bar never jumps backward.
- **Asymptotic.** The curve is bounded below 95 for any finite `n`, so the estimate
  cannot reach 100% on its own. Only `Stop` / `StopFailure` completes the bar. This is
  what keeps the widget from claiming "done" while work is still running — the failure
  mode that would make it worse than useless.

It is still not a measurement: `n` counts tool calls, not work, and a turn that is one
slow call reads lower than a turn that is ten fast ones. It is labeled `(est.)` in the
status line for exactly that reason. Model self-reporting stays rejected — it fails the
monotonicity property above, which is the whole basis for showing a number here.

**Known limitation to accept, not paper over:** todo items are not equal-sized, so
3/6 does not mean half the wall-clock work is done. The bar is a coarse indicator of
plan position, not an ETA. Do not add weighting heuristics — they add complexity
without adding information.

## 5. Architecture

```
any tool call ──PostToolUse──▶  /tmp/claude-activity-<session_id>  (size = call count)
   └── if TodoWrite ──────────▶  /tmp/claude-progress-<session_id>  ("2/5")
                                                    │
UserPromptSubmit ──raises─────▶  /tmp/claude-busy-<session_id>      │
                 └─empties activity, deletes progress      │        │
Stop / StopFailure ──lowers───▶  (existence = flag)        │        │
                                                    ▼      ▼        ▼
                                                    statusLine script
                                                            │
                                                            ▼
                                    row 1: model · dir · [bar] label · ctx
                                    row 2: keyboard hints
```

**Turn lifecycle.** `UserPromptSubmit` empties the activity counter and deletes the todo
ratio, so the bar restarts at 0% on every prompt. `Stop` lowers the busy flag but leaves
the activity file: a counter that outlives its busy flag is precisely how the status line
recognizes a finished turn and draws 100%. The two files are read together as a small
state machine — no activity file means no turn has started (`idle`).

Decoupled processes communicating through small files in `/tmp`. Hooks are the only
writers; the status line is the only reader. Neither imports the other.

**File permissions.** Both state files are opened with `O_NOFOLLOW` and mode `0600`, and
the reader uses `lstat` rather than `stat`. `/tmp` is world-writable, so without that a
symlink pre-planted at either path would make a hook truncate whatever it points at.
`session_id` is a UUID, so this was never practically exploitable; the guard is free.

**Why keyed on `session_id`:** concurrent Claude Code sessions in different repos
would otherwise overwrite each other's progress state. `session_id` is stable for a
session's lifetime and unique across sessions. Do not use PID — it changes on every
invocation.

## 6. Components

### 6.1 `todo-progress-hook.py` (PostToolUse, all tools)

- **Input:** hook JSON on stdin, containing `session_id`, `tool_name`, `tool_input`.
- **Behavior:** if `tool_name == "TodoWrite"`, count `tool_input.todos` entries whose
  `status == "completed"` and write `"<done>/<total>"` to the progress file. Then, for
  *every* tool call, append one byte to the activity file.
- **Why one appended byte rather than a rewritten integer:** `O_APPEND` writes cannot
  interleave, so overlapping tool calls each get counted. A read-modify-write counter
  would drop increments under concurrency. The count is the file's size.
- **Failure mode:** swallow every exception and exit 0. A hook that errors must never
  interfere with the tool call that triggered it. The two writes are guarded
  independently, so a symlink planted at one path cannot suppress the other.
- **Cost:** this now runs on every tool call rather than only on `TodoWrite` — one
  short-lived Python process per call, against a tool call that is already slower than
  that.

### 6.2 `statusline-progress.py` (statusLine command)

- **Input:** status line JSON on stdin.
- **Behavior:**
  1. Read the progress file for `session_id`. If present and `total > 0`,
     `pct = done/total`, label `"N% (done/total tasks)"`.
  2. Otherwise read the activity counter. Absent → `0% idle`. Present and the busy flag
     is up → `pct = 95·n/(n+6)`, label `"N% (est.)"`. Present and the busy flag is down →
     the turn has ended, `100%`.
  3. Render a 12-cell bar: green `█` for filled, dim `░` for remainder. Any nonzero
     percentage draws at least one cell, so 1–4% is not visually identical to nothing.
  4. Print row 1: `model · dirname · [bar] label · N% ctx`, the last segment dim and
     omitted when `used_percentage` is null.
  5. Print row 2: the hints from §6.3.
- **Rounding:** halves round up. Python's built-in `round()` is half-to-even, which makes
  the percentage table look wrong to anyone checking it by hand.
- **Colors:** ANSI `\033[32m` green, `\033[2m` dim, `\033[0m` reset.

### 6.3 `turn-state-hook.py` (UserPromptSubmit, Stop, StopFailure)

Owns turn boundaries. It does two jobs that both need to know when a turn starts and
ends: restoring the keyboard hints, and resetting the progress bar.

**The hints.** Configuring a `statusLine` suppresses the footer's keyboard hints. They
are only cosmetic — `esc` still interrupts either way — but losing the reminder is the
single largest cost of using this project at all. Nothing in the status line's stdin
reports whether a turn is in flight, so an unconditional `esc to interrupt` would be
wrong whenever the session is idle. Instead `UserPromptSubmit` creates
`/tmp/claude-busy-<session_id>` and `Stop` / `StopFailure` delete it. Existence is the
flag — there are no contents to parse.

**The reset.** `UserPromptSubmit` also empties `/tmp/claude-activity-<session_id>` and
deletes `/tmp/claude-progress-<session_id>`, which is what makes the bar restart at 0%
on each prompt rather than carrying the previous turn's number. On `Stop` the activity
file is deliberately left in place: the status line reads "activity file present, busy
flag absent" as a completed turn and draws 100%.

**Two constraints specific to this hook**, both from the `UserPromptSubmit` contract:
stdout is injected into the conversation as context, so it must print nothing; and exit
code 2 blocks the user's prompt, so it must exit 0 unconditionally.

**Unresolved:** `Stop` fires when Claude finishes responding and `StopFailure` when a turn
ends due to an API error. Neither is documented as firing when the user interrupts with
`esc`. If neither does, the flag stays up until the next prompt is submitted, the hint is
wrong for exactly that window — and now the bar is wrong too, frozen mid-estimate instead
of completing. The per-turn bar raises the stakes on this; it does not change the answer.
Needs a live test (§8.10). Do not paper over this with a staleness timeout — that would
misreport long legitimate turns, which is the failure mode that matters more.

### 6.4 Settings

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

## 7. Edge cases

| Case | Required behavior |
|---|---|
| No state files at all (fresh session, no prompt yet) | `0% idle` |
| Turn in flight with no todo list | Estimate from tool-call count, labeled `(est.)` |
| Turn in flight with zero tool calls so far | `0% (est.)` — the estimate's honest floor |
| `context_window.used_percentage` is `null` (before first API response, and after `/compact`) | Omit the `ctx` suffix entirely; the bar is unaffected |
| Empty todo list (`total == 0`) | Fall back to the estimate; must not divide by zero |
| Percentage rounds below one cell (1–4%) | Draw one cell anyway — an empty bar reads as broken |
| Malformed / non-JSON hook stdin | Exit 0 silently, leave state files untouched |
| Two tool calls finishing at once | Both counted — `O_APPEND` writes cannot interleave |
| Stale `/tmp` file from a prior session | Harmless — new session has a new `session_id` |
| Very narrow terminal | Bar is fixed at 12 cells; total line stays short enough to survive truncation |
| Busy flag cleared when already clear | `unlink` raises `FileNotFoundError`; swallowed, exit 0 |
| Symlink pre-planted at any state path | Write refuses (`O_NOFOLLOW`); read treats it as absent and falls back |
| Turn interrupted with `esc` | Unresolved — see §6.3 |

## 8. Success criteria

Criteria 1-9 and 11-13 are automated in `./test.sh` (49 assertions). Criteria 10 and 14
require a live session and must be checked by hand.

1. `echo '<mock TodoWrite JSON>' | ./todo-progress-hook.py` exits 0 and writes the
   expected `done/total` to `/tmp/claude-progress-<id>`.
2. `echo '<mock statusline JSON>' | ./statusline-progress.py` with that state file
   present prints a bar whose filled-cell count matches the todo ratio.
3. Every tool call appends exactly one byte to `/tmp/claude-activity-<id>`.
4. `UserPromptSubmit` empties the activity counter and deletes the todo ratio, so the
   next render reads `0% (est.)`.
5. With the busy flag up, 1 / 6 / 20 tool calls render 14% / 48% / 73%.
6. The estimate never decreases across a 20-call sweep, and 500 calls still reads 94% —
   it cannot reach 100% while the turn is in flight.
7. `Stop` and `StopFailure` each complete the bar at 100%.
8. A todo ratio outranks the estimate whenever both exist.
9. `used_percentage: null` omits the `ctx` suffix rather than crashing; an empty todo
   list does not produce a `ZeroDivisionError`; non-JSON stdin to either hook exits 0.
10. In a live session, the bar advances as Claude marks todos complete, and continues
    updating during a long turn with no new assistant message (validates
    `refreshInterval`).
11. The hint row reads `esc to interrupt · ? for shortcuts` while the busy flag is up and
    `? for shortcuts` when it is down.
12. A symlink planted at any of the three state paths is neither written through nor
    read through.
13. A percentage that rounds below one cell still draws one cell.
14. **Live test, currently unverified.** Interrupt a turn with `esc`. The hint row must
    drop back to `? for shortcuts` and the bar must complete at 100%. If the hint sticks
    until the next prompt, neither `Stop` nor `StopFailure` fires on interrupt and §6.3
    needs another event — not a timeout.

## 9. Open questions

- **Color thresholds.** Bar is currently always green. Should context-fallback mode
  shift green → yellow → red as context fills, while todo mode stays green? Two
  different meanings sharing one widget is a legibility risk.
- **In-progress items.** Should an `in_progress` todo count as a half-cell, or is that
  false precision?
- **Distribution.** Ship as dotfiles, or package as a Claude Code plugin so
  `statusLine` and `hooks` install together?

## 10. Future work (explicitly out of scope for v1)

- Subagent progress rows via the `subagentStatusLine` setting.
- Elapsed-time or cost segments alongside the bar.
- Per-project overrides via `.claude/settings.json` at a repo root.
