#!/usr/bin/env python3
"""Claude Code status line: green progress bar.
 
Shows todo-list progress when a TodoWrite state file exists for this session,
otherwise falls back to context-window usage.
"""
import json
import os
import sys
 
BAR_WIDTH = 12
GREEN = "\033[32m"
DIM = "\033[2m"
RESET = "\033[0m"
 
 
def bar(pct):
    filled = round(pct * BAR_WIDTH / 100)
    return f"{GREEN}{'█' * filled}{RESET}{DIM}{'░' * (BAR_WIDTH - filled)}{RESET}"
 
 
def read_task_progress(session_id):
    """Return (done, total) from the state file the TodoWrite hook writes."""
    path = f"/tmp/claude-progress-{session_id}"
    try:
        with open(path) as f:
            done, total = (int(x) for x in f.read().strip().split("/"))
        return (done, total) if total > 0 else None
    except (OSError, ValueError):
        return None
 
 
def main():
    data = json.load(sys.stdin)
    model = data.get("model", {}).get("display_name", "Claude")
    cwd = os.path.basename(data.get("workspace", {}).get("current_dir", ""))
 
    progress = read_task_progress(data.get("session_id", ""))
    if progress:
        done, total = progress
        pct = round(done * 100 / total)
        detail = f"{pct}% {DIM}({done}/{total} tasks){RESET}"
    else:
        pct = int(data.get("context_window", {}).get("used_percentage") or 0)
        detail = f"{pct}% {DIM}context{RESET}"
 
    print(f"{model} {DIM}·{RESET} {cwd} {DIM}·{RESET} {bar(pct)} {detail}")
 
 
if __name__ == "__main__":
    main()