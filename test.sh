#!/usr/bin/env bash
# Test battery for the status line and its hooks.
# Every case in DESIGN.md section 8, plus the turn-state hint row, the
# per-turn progress lifecycle, and the symlink guards. Run from the repo
# root: ./test.sh
set -u

PASS=0
FAIL=0
S=test-$$

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n' "$1"
    printf '       expected: %s\n' "$2"
    printf '       actual:   %s\n' "$3"
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
    case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "contains '$2'" "$3" ;;
    esac
}

# assert_omits <name> <needle> <haystack>
assert_omits() {
    case "$3" in
    *"$2"*) fail "$1" "does not contain '$2'" "$3" ;;
    *) pass "$1" ;;
    esac
}

# assert_equals <name> <expected> <actual>
assert_equals() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

# Strip ANSI escapes so assertions match on visible text.
plain() { sed $'s/\033\\[[0-9;]*m//g'; }

todo_json() { printf '{"session_id":"%s","tool_name":"TodoWrite","tool_input":{"todos":[%s]}}' "$1" "$2"; }
tool_json() { printf '{"session_id":"%s","tool_name":"%s","tool_input":{}}' "$1" "$2"; }
status_json() { printf '{"session_id":"%s","model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/x/demo"},"context_window":{"used_percentage":%s}}' "$1" "$2"; }
hook_json() { printf '{"session_id":"%s","hook_event_name":"%s"}' "$1" "$2"; }

# row1 <session> <context_pct> -> visible text of the bar row
row1() { status_json "$1" "$2" | ./statusline-progress.py | head -1 | plain; }
# hintrow <session> -> visible text of the hint row
hintrow() { status_json "$1" 7 | ./statusline-progress.py | plain | tail -1; }
# calls <session> <n> -> simulate n non-TodoWrite tool calls through the hook
calls() { i=0; while [ "$i" -lt "$2" ]; do tool_json "$1" Read | ./todo-progress-hook.py; i=$((i + 1)); done; }
# set_activity <session> <n> -> put the counter at exactly n without spawning
# n hook processes. The hook's own append behavior is covered above; these
# cases exercise the status line's curve, so writing the bytes directly keeps
# the sweep fast enough to run.
set_activity() { head -c "$2" /dev/zero >"/tmp/claude-activity-$1"; }
# pct_of <row1 text> -> the leading percentage of the bar label, digits only
pct_of() { printf '%s\n' "$1" | sed -E 's/.*░ ([0-9]+)%.*/\1/; s/.*█ ([0-9]+)%.*/\1/'; }

cleanup() { rm -f "/tmp/claude-progress-$S" "/tmp/claude-busy-$S" "/tmp/claude-activity-$S"; }
trap cleanup EXIT
cleanup

echo "== todo progress hook =="

out=$(todo_json "$S" '{"status":"completed"},{"status":"completed"},{"status":"in_progress"},{"status":"pending"},{"status":"pending"}' | ./todo-progress-hook.py)
assert_equals "hook exits 0" "0" "$?"
assert_equals "hook writes done/total" "2/5" "$(cat "/tmp/claude-progress-$S")"
assert_equals "state file is 0600" "-rw-------" "$(stat -f '%Sp' "/tmp/claude-progress-$S")"
assert_equals "hook prints nothing" "" "$out"

echo 'not json' | ./todo-progress-hook.py >/dev/null 2>&1
assert_equals "hook survives non-JSON stdin" "0" "$?"

tool_json "$S" Read | ./todo-progress-hook.py
assert_equals "non-TodoWrite tool leaves todo state intact" "2/5" "$(cat "/tmp/claude-progress-$S")"

echo "== activity counter =="

cleanup
tool_json "$S" Read | ./todo-progress-hook.py
assert_equals "a tool call creates the activity file" "1" "$(stat -f '%z' "/tmp/claude-activity-$S")"
assert_equals "activity file is 0600" "-rw-------" "$(stat -f '%Sp' "/tmp/claude-activity-$S")"

calls "$S" 4
assert_equals "each tool call appends one byte" "5" "$(stat -f '%z' "/tmp/claude-activity-$S")"

todo_json "$S" '{"status":"pending"}' | ./todo-progress-hook.py
assert_equals "TodoWrite counts as activity too" "6" "$(stat -f '%z' "/tmp/claude-activity-$S")"

echo "== per-turn lifecycle =="

cleanup
assert_contains "fresh session is idle" "0% idle" "$(row1 "$S" 12)"

hook_json "$S" UserPromptSubmit | ./turn-state-hook.py
assert_contains "a new prompt starts the bar at 0%" "0% (est.)" "$(row1 "$S" 12)"

calls "$S" 1
assert_contains "one tool call reads 14%" "14% (est.)" "$(row1 "$S" 12)"

calls "$S" 5
assert_contains "six tool calls read 48%" "48% (est.)" "$(row1 "$S" 12)"

calls "$S" 14
assert_contains "twenty tool calls read 73%" "73% (est.)" "$(row1 "$S" 12)"

hook_json "$S" Stop | ./turn-state-hook.py
assert_contains "Stop completes the bar" "100%" "$(row1 "$S" 12)"

hook_json "$S" UserPromptSubmit | ./turn-state-hook.py
assert_contains "the next prompt resets to 0%" "0% (est.)" "$(row1 "$S" 12)"

hook_json "$S" StopFailure | ./turn-state-hook.py
assert_contains "StopFailure also completes the bar" "100%" "$(row1 "$S" 12)"

echo "== the estimate is monotonic and never fakes completion =="

cleanup
hook_json "$S" UserPromptSubmit | ./turn-state-hook.py
prev=0
regressed=""
i=1
while [ "$i" -le 20 ]; do
    set_activity "$S" "$i"
    cur=$(pct_of "$(row1 "$S" 12)")
    [ "$cur" -lt "$prev" ] && regressed="dropped $prev -> $cur at call $i"
    prev=$cur
    i=$((i + 1))
done
assert_equals "estimate never decreases over 20 calls" "" "$regressed"

set_activity "$S" 500
assert_equals "500 calls still does not reach 100% while busy" "94" "$(pct_of "$(row1 "$S" 12)")"

echo "== a real todo ratio outranks the estimate =="

cleanup
hook_json "$S" UserPromptSubmit | ./turn-state-hook.py
calls "$S" 20
todo_json "$S" '{"status":"completed"},{"status":"pending"},{"status":"pending"},{"status":"pending"}' | ./todo-progress-hook.py
line1=$(row1 "$S" 12)
assert_contains "todo mode wins over the estimate" "25% (1/4 tasks)" "$line1"
assert_contains "todo mode fills 3 of 12 cells" "███░░░░░░░░░" "$line1"

todo_json "$S" '' | ./todo-progress-hook.py
assert_contains "an empty todo list falls back to the estimate" "% (est.)" "$(row1 "$S" 12)"

echo "== context is dim trailing text, not the bar =="

cleanup
assert_contains "context rides at the end of the row" "42% ctx" "$(row1 "$S" 42)"
assert_omits "context does not drive the bar" "42% context" "$(row1 "$S" 42)"

line1=$(printf '{"session_id":"none","model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/x/demo"},"context_window":{"used_percentage":null}}' | ./statusline-progress.py | head -1 | plain)
assert_omits "null used_percentage prints no ctx suffix" "ctx" "$line1"
assert_contains "null used_percentage still renders the bar" "0% idle" "$line1"

echo "== a nonzero bar always shows at least one cell =="

cleanup
hook_json "$S" UserPromptSubmit | ./turn-state-hook.py
todo_json "$S" '{"status":"completed"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"},{"status":"pending"}' | ./todo-progress-hook.py
line1=$(row1 "$S" 12)
assert_contains "4% draws one cell rather than none" "█░░░░░░░░░░░" "$line1"
assert_contains "and still reports the true number" "4% (1/25 tasks)" "$line1"

echo "== status line: hint row =="

cleanup
out=$(status_json "$S" 7 | ./statusline-progress.py | plain)
assert_equals "idle prints two rows" "2" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_equals "idle hint row omits interrupt" "? for shortcuts" "$(printf '%s\n' "$out" | tail -1)"

hook_json "$S" UserPromptSubmit | ./turn-state-hook.py
assert_equals "busy hint row offers interrupt" "esc to interrupt · ? for shortcuts" "$(hintrow "$S")"

hook_json "$S" Stop | ./turn-state-hook.py
assert_equals "Stop clears busy flag" "? for shortcuts" "$(hintrow "$S")"

hook_json "$S" UserPromptSubmit | ./turn-state-hook.py
hook_json "$S" StopFailure | ./turn-state-hook.py
assert_equals "StopFailure clears busy flag" "? for shortcuts" "$(hintrow "$S")"

echo "== turn-state hook contract =="

out=$(hook_json "$S" UserPromptSubmit | ./turn-state-hook.py)
assert_equals "hook exits 0" "0" "$?"
# UserPromptSubmit stdout is injected into the conversation as context.
assert_equals "hook prints nothing on stdout" "" "$out"
assert_equals "busy file is 0600" "-rw-------" "$(stat -f '%Sp' "/tmp/claude-busy-$S")"
assert_equals "activity file is reset to empty" "0" "$(stat -f '%z' "/tmp/claude-activity-$S")"

todo_json "$S" '{"status":"completed"}' | ./todo-progress-hook.py
hook_json "$S" UserPromptSubmit | ./turn-state-hook.py
assert_equals "a new prompt drops last turn's todo ratio" "1" "$([ -e "/tmp/claude-progress-$S" ] && echo 0 || echo 1)"

hook_json "$S" Stop | ./turn-state-hook.py
hook_json "$S" Stop | ./turn-state-hook.py
assert_equals "clearing an already-clear flag exits 0" "0" "$?"

echo 'not json' | ./turn-state-hook.py >/dev/null 2>&1
assert_equals "turn hook survives non-JSON stdin" "0" "$?"

cleanup
hook_json "$S" PostToolUse | ./turn-state-hook.py
assert_equals "unrelated event is a no-op" "? for shortcuts" "$(hintrow "$S")"
assert_contains "unrelated event leaves the bar idle" "0% idle" "$(row1 "$S" 12)"

echo "== symlink guards (/tmp is world-writable) =="

D=$(mktemp -d)

cleanup
echo "IMPORTANT DATA" >"$D/victim"
ln -s "$D/victim" "/tmp/claude-progress-$S"
todo_json "$S" '{"status":"completed"},{"status":"pending"}' | ./todo-progress-hook.py
assert_equals "todo hook will not write through a symlink" "IMPORTANT DATA" "$(cat "$D/victim")"

cleanup
echo "9/9" >"$D/fake"
ln -s "$D/fake" "/tmp/claude-progress-$S"
assert_contains "status line will not read a symlinked ratio" "0% idle" "$(row1 "$S" 12)"

cleanup
echo "IMPORTANT DATA" >"$D/victim2"
ln -s "$D/victim2" "/tmp/claude-busy-$S"
hook_json "$S" UserPromptSubmit | ./turn-state-hook.py
assert_equals "turn hook will not write through a symlinked busy flag" "IMPORTANT DATA" "$(cat "$D/victim2")"
assert_equals "symlinked busy flag does not read as busy" "? for shortcuts" "$(hintrow "$S")"

cleanup
echo "IMPORTANT DATA" >"$D/victim3"
ln -s "$D/victim3" "/tmp/claude-activity-$S"
tool_json "$S" Read | ./todo-progress-hook.py
assert_equals "activity counter will not append through a symlink" "IMPORTANT DATA" "$(cat "$D/victim3")"
assert_contains "symlinked activity file does not read as progress" "0% idle" "$(row1 "$S" 12)"

rm -rf "$D"
cleanup

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
