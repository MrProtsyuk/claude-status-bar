#!/usr/bin/env python3
"""Mark turn boundaries so the status line can draw per-turn progress.

`UserPromptSubmit` opens a turn: it raises the busy flag, empties the activity
counter, and drops the previous turn's todo ratio, so every prompt starts the
bar at 0%. `Stop` / `StopFailure` lower the busy flag and leave the activity
file behind — a counter outliving its busy flag is how the status line knows
the turn finished and the bar has earned 100%.

Prints nothing: `UserPromptSubmit` stdout is injected into the conversation as
context. Exits 0 unconditionally: exit 2 would block the user's prompt.
"""
import json
import os
import sys

OPEN_EVENTS = {"UserPromptSubmit"}
CLOSE_EVENTS = {"Stop", "StopFailure"}


def truncate(path):
    """Create `path`, or empty it if it already exists."""
    # O_NOFOLLOW: /tmp is world-writable, so a symlink pre-planted at this
    # path would otherwise make us truncate whatever it points at.
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
    os.close(os.open(path, flags, 0o600))


def remove(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def main():
    try:
        data = json.load(sys.stdin)
        session = data["session_id"]
    except Exception:
        return
    event = data.get("hook_event_name")
    busy = f"/tmp/claude-busy-{session}"
    activity = f"/tmp/claude-activity-{session}"
    progress = f"/tmp/claude-progress-{session}"

    if event in OPEN_EVENTS:
        # Guarded one path at a time: a symlink planted at either file must
        # not stop the other from being reset.
        for path in (busy, activity):
            try:
                truncate(path)
            except OSError:
                pass
        remove(progress)
    elif event in CLOSE_EVENTS:
        remove(busy)


if __name__ == "__main__":
    main()
    sys.exit(0)
