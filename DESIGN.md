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
| A custom status line suppresses most footer keyboard hints, including `esc to interrupt` | Accepted tradeoff; note it in the README |
| Status line re-runs only on: session start, new assistant message, `/compact` finish, permission-mode change, vim toggle, or `refreshInterval` timer | `refreshInterval` is **required**, or the bar freezes during long agentic turns |
| Updates debounce at 300ms; an in-flight script is cancelled if a new trigger fires | Script must be fast — no git calls, no subprocesses |
| Only stdout is displayed; non-zero exit or empty output blanks the status line | Never raise; always print exactly one line |
| `statusLine` executes a shell command, so it is gated by workspace trust | Trust dialog must be accepted or the row stays blank |

## 4. Key design decision: what is the denominator?

"Percent complete" is not a quantity the agent has. Three candidate signals were
considered:

| Source | Real task progress? | Verdict |
|---|---|---|
| `context_window.used_percentage` | No — measures context fill, not work done | **Fallback only** |
| Todo list (`completed / total` from `TodoWrite`) | Yes | **Primary** |
| Model self-reporting a percentage | No — fabricated, non-monotonic | Rejected |

**Decision:** drive the bar from todo-list completion when a todo list exists for the
session; fall back to context usage otherwise, so the bar is never blank or fake.

**Known limitation to accept, not paper over:** todo items are not equal-sized, so
3/6 does not mean half the wall-clock work is done. The bar is a coarse indicator of
plan position, not an ETA. Do not add weighting heuristics — they add complexity
without adding information.

## 5. Architecture

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

Two decoupled processes communicating through one small file. The hook is the only
writer; the status line is the only reader. Neither imports the other.

**Why keyed on `session_id`:** concurrent Claude Code sessions in different repos
would otherwise overwrite each other's progress state. `session_id` is stable for a
session's lifetime and unique across sessions. Do not use PID — it changes on every
invocation.

## 6. Components

### 6.1 `todo-progress-hook.py` (PostToolUse, matcher `TodoWrite`)

- **Input:** hook JSON on stdin, containing `session_id`, `tool_name`, `tool_input`.
- **Behavior:** if `tool_name == "TodoWrite"`, count `tool_input.todos` entries whose
  `status == "completed"`; write `"<done>/<total>"` to the state file.
- **Failure mode:** swallow every exception and exit 0. A hook that errors must never
  interfere with the tool call that triggered it.

### 6.2 `statusline-progress.py` (statusLine command)

- **Input:** status line JSON on stdin.
- **Behavior:**
  1. Read state file for `session_id`. If present and `total > 0`, `pct = done/total`,
     label `"N% (done/total tasks)"`.
  2. Otherwise `pct = context_window.used_percentage or 0`, label `"N% context"`.
  3. Render a 12-cell bar: green `█` for filled, dim `░` for remainder.
  4. Print one line: `model · dirname · [bar] label`.
- **Colors:** ANSI `\033[32m` green, `\033[2m` dim, `\033[0m` reset.

### 6.3 Settings

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline-progress.py",
    "refreshInterval": 2
  },
  "hooks": {
    "PostToolUse": [
      { "matcher": "TodoWrite",
        "hooks": [{ "type": "command", "command": "~/.claude/todo-progress-hook.py" }] }
    ]
  }
}
```

## 7. Edge cases

| Case | Required behavior |
|---|---|
| No state file (fresh session, no todos yet) | Fall back to context bar |
| `context_window.used_percentage` is `null` (before first API response, and after `/compact`) | Treat as 0, print bar at 0% |
| Empty todo list (`total == 0`) | Fall back to context bar; must not divide by zero |
| Malformed / non-JSON hook stdin | Exit 0 silently, leave state file untouched |
| Hook fires for a non-`TodoWrite` tool | No-op |
| Stale `/tmp` file from a prior session | Harmless — new session has a new `session_id` |
| Very narrow terminal | Bar is fixed at 12 cells; total line stays short enough to survive truncation |

## 8. Success criteria

Implementation is done when all of the following pass:

1. `echo '<mock TodoWrite JSON>' | ./todo-progress-hook.py` exits 0 and writes the
   expected `done/total` to `/tmp/claude-progress-<id>`.
2. `echo '<mock statusline JSON>' | ./statusline-progress.py` with that state file
   present prints a bar whose filled-cell count matches the todo ratio.
3. The same command with no state file prints a context-based bar.
4. `used_percentage: null` prints a 0% bar rather than crashing.
5. An empty todo list does not produce a `ZeroDivisionError`.
6. Non-JSON stdin to the hook exits 0.
7. In a live session, the bar advances as Claude marks todos complete, and continues
   updating during a long turn with no new assistant message (validates
   `refreshInterval`).

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
