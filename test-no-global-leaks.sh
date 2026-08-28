#!/bin/bash
# Guards against forward-reference scope bugs in init.lua.
#
# Lua resolves a name against the locals visible at the point the enclosing
# function is COMPILED. Assigning or calling something declared later in the
# file silently targets a global instead of the intended local — no syntax
# error, no warning, just a write that goes nowhere or a call on nil.
#
# Two real bugs of this shape shipped here:
#   - the max-session watchdog's `insertKeyIsDown = false` created a global,
#     so the logical key state stayed stuck down
#   - the same watchdog's `stopRecording()` resolved to nil, so the 120s
#     recording limit never fired at all
#
# Every global init.lua touches must therefore be a genuine external name.

set -u
cd "$(dirname "$0")"

command -v luac >/dev/null || { echo "SKIP: luac not installed (brew install lua)"; exit 0; }
luac -p init.lua || { echo "FAIL: init.lua does not compile"; exit 1; }

ALLOWED="hs io math os print require string table tostring tonumber pcall type ipairs pairs select error assert setmetatable getmetatable next unpack"

# One deliberate global. init.lua's chunk is released after loading, so
# chunk-level locals holding taps/timers/watchers become collectable and are
# silently freed by a GC cycle. PTT_RUNTIME is reachable from _ENV, making
# everything stored in it a GC root. Any OTHER global is still a bug.
INTENTIONAL="PTT_RUNTIME"

leaks=0

written=$(luac -l -l init.lua 2>/dev/null \
    | grep -oE 'SETTABUP.*_ENV "[A-Za-z_][A-Za-z0-9_]*"' \
    | grep -oE '"[A-Za-z_][A-Za-z0-9_]*"' | tr -d '"' | sort -u)
for name in $written; do
    case " $INTENTIONAL " in
        *" $name "*) echo "  note: intentional global '$name' (GC anchor)"; continue ;;
    esac
    echo "FAIL: init.lua writes global '$name' (declare it as a local before first use)"
    leaks=1
done

read_globals=$(luac -l -l init.lua 2>/dev/null \
    | grep -oE 'GETTABUP.*_ENV "[A-Za-z_][A-Za-z0-9_]*"' \
    | grep -oE '"[A-Za-z_][A-Za-z0-9_]*"' | tr -d '"' | sort -u)
for name in $read_globals; do
    case " $ALLOWED $INTENTIONAL " in
        *" $name "*) ;;
        *) echo "FAIL: init.lua reads undeclared global '$name' (forward-declare it)"; leaks=1 ;;
    esac
done

if [ "$leaks" -eq 0 ]; then
    echo "PASS - no accidental globals; every local resolves as intended"
    exit 0
fi
exit 1
