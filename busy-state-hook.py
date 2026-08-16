#!/usr/bin/env python3
"""Track whether a turn is in flight, so the status line can show hints.

A custom status line suppresses the footer's keyboard hints, including
`esc to interrupt`. Nothing in the status line's stdin says whether Claude is
working, so `UserPromptSubmit` raises a flag and `Stop` / `StopFailure` lower
it; the status line shows the interrupt hint only while the flag is up.

Prints nothing: `UserPromptSubmit` stdout is injected into the conversation as
context. Exits 0 unconditionally: exit 2 would block the user's prompt.
"""
import json
import os
import sys

SET_EVENTS = {"UserPromptSubmit"}
CLEAR_EVENTS = {"Stop", "StopFailure"}


def main():
    try:
        data = json.load(sys.stdin)
        event = data.get("hook_event_name")
        path = f"/tmp/claude-busy-{data['session_id']}"
        if event in SET_EVENTS:
            # O_NOFOLLOW: /tmp is world-writable, so a symlink pre-planted at
            # this path would otherwise make us truncate whatever it points at.
            flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
            os.close(os.open(path, flags, 0o600))
        elif event in CLEAR_EVENTS:
            os.unlink(path)
    except Exception:
        pass


if __name__ == "__main__":
    main()
    sys.exit(0)
