#!/usr/bin/env python3
"""Claude Code status line: a green progress bar for the current turn.

The bar starts at 0% on every prompt and reaches 100% when the turn ends.
In between it prefers measured todo-list progress and falls back to an
estimate derived from tool-call count. Context usage rides along as dim
trailing text — it is not task progress, so it does not drive the bar.

A second row carries the keyboard hints a custom status line suppresses.
"""
import json
import os
import stat
import sys

BAR_WIDTH = 12
# The estimate approaches this and never arrives; only the end of the turn
# reaches 100. See DESIGN.md section 4.
CEILING = 95
# Tool calls at which the estimate passes half of CEILING.
HALFWAY = 6

GREEN = "\033[32m"
DIM = "\033[2m"
RESET = "\033[0m"


def half_up(x):
    """Round halves upward. Python's round() is half-to-even, which makes the
    percentage table read as if it were wrong."""
    return int(x + 0.5)


def bar(pct):
    filled = half_up(pct * BAR_WIDTH / 100)
    if pct > 0:
        # Below 5% the bar would otherwise round to nothing and read as dead.
        filled = max(1, filled)
    return f"{GREEN}{'█' * filled}{RESET}{DIM}{'░' * (BAR_WIDTH - filled)}{RESET}"


def read_todo_ratio(session):
    """(done, total) from the state file the TodoWrite hook writes, or None."""
    path = f"/tmp/claude-progress-{session}"
    try:
        # O_NOFOLLOW: refuse to read through a symlink planted in world-writable /tmp.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd) as f:
            done, total = (int(x) for x in f.read().strip().split("/"))
        return (done, total) if total > 0 else None
    except (OSError, ValueError):
        return None


def read_tool_calls(session):
    """Tool calls so far this turn, or None if no turn has started.

    The counter is the file's size: the hook appends one byte per call.
    """
    try:
        # lstat, not stat: a symlink at this path is not a file we wrote.
        st = os.lstat(f"/tmp/claude-activity-{session}")
        return st.st_size if stat.S_ISREG(st.st_mode) else None
    except OSError:
        return None


def estimate(calls):
    """Percent complete guessed from tool-call count.

    calls/(calls + HALFWAY) rises quickly at first and flattens out, and is
    bounded below 1 for any finite count, so the bar climbs steadily through a
    long turn without ever claiming to be finished while work is still running.
    """
    return half_up(CEILING * calls / (calls + HALFWAY))


def is_busy(session):
    """True while a turn is in flight, per the turn-state hook."""
    try:
        return stat.S_ISREG(os.lstat(f"/tmp/claude-busy-{session}").st_mode)
    except OSError:
        return False


def progress(session):
    """(percent, label) for the bar."""
    ratio = read_todo_ratio(session)
    if ratio:
        done, total = ratio
        return half_up(done * 100 / total), f"({done}/{total} tasks)"

    calls = read_tool_calls(session)
    if calls is None:
        return 0, "idle"
    if is_busy(session):
        return estimate(calls), "(est.)"
    return 100, ""


def context(data):
    """Dim trailing note on context-window usage, or nothing if unreported."""
    used = data.get("context_window", {}).get("used_percentage")
    if used is None:
        return ""
    return f" {DIM}·{RESET} {DIM}{int(used)}% ctx{RESET}"


def hints(session):
    """The footer hints Claude Code stops drawing once a status line exists."""
    parts = ["esc to interrupt"] if is_busy(session) else []
    parts.append("? for shortcuts")
    return f"{DIM}{' · '.join(parts)}{RESET}"


def main():
    data = json.load(sys.stdin)
    model = data.get("model", {}).get("display_name", "Claude")
    cwd = os.path.basename(data.get("workspace", {}).get("current_dir", ""))
    session = data.get("session_id", "")

    pct, label = progress(session)
    detail = f"{pct}% {DIM}{label}{RESET}" if label else f"{pct}%"

    print(f"{model} {DIM}·{RESET} {cwd} {DIM}·{RESET} {bar(pct)} {detail}{context(data)}")
    print(hints(session))


if __name__ == "__main__":
    main()
