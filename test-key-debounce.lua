-- Regression test: holding Insert must produce exactly ONE start/stop pair,
-- even when the keyboard emits a spurious keyUp mid-hold (Wooting rapid trigger)
-- while macOS auto-repeat keeps delivering keyDown events.
--
-- Models the keyDown/keyUp state machine from init.lua lines 896-960 with a
-- virtual clock, so no audio/recording side effects are needed.

local DEBOUNCE_MS = 300

local function runSim(variant)
    local now, timers = 0, {}
    local function doAfter(delay, fn)
        local t = { at = now + delay, fn = fn, dead = false }
        timers[#timers + 1] = t
        return { stop = function() t.dead = true end }
    end
    local function advanceTo(target)
        while true do
            local nxt
            for _, t in ipairs(timers) do
                if not t.dead and t.at <= target and (not nxt or t.at < nxt.at) then nxt = t end
            end
            if not nxt then break end
            now = nxt.at
            nxt.dead = true
            nxt.fn()
        end
        now = target
    end

    local insertKeyIsDown, keyUpDebounceTimer = false, nil
    local isRecording = false
    local starts, stops, cancels = 0, 0, 0

    local function startRecording()
        if isRecording then return end
        isRecording = true
        starts = starts + 1          -- playStartSound() -- "Morse"
    end
    local function stopRecording()
        if not isRecording then return end
        isRecording = false
        stops = stops + 1            -- playStopSound() -- "Pop"
    end

    local function keyDown()
        if variant == "fixed" then
            -- A pending debounce means a keyUp is in flight; a keyDown before it
            -- expires proves the key is still held, so cancel the pending stop.
            -- This MUST be checked before the held-key fast path.
            if keyUpDebounceTimer then
                keyUpDebounceTimer:stop()
                keyUpDebounceTimer = nil
                cancels = cancels + 1
                return
            end
            if insertKeyIsDown then return end
        else -- "current" -- init.lua as written
            if insertKeyIsDown then return end          -- fast path, line 917
            if keyUpDebounceTimer then                  -- line 932
                keyUpDebounceTimer:stop()
                keyUpDebounceTimer = nil
                cancels = cancels + 1
                return
            end
        end
        insertKeyIsDown = true
        startRecording()
    end

    local function keyUp()
        if keyUpDebounceTimer then keyUpDebounceTimer:stop() end
        keyUpDebounceTimer = doAfter(DEBOUNCE_MS / 1000, function()
            keyUpDebounceTimer = nil
            insertKeyIsDown = false
            stopRecording()
        end)
    end

    -- One physical hold: press at t=0, release at t=3.0.
    -- macOS auto-repeat delivers a keyDown every 30ms for the whole hold.
    -- The keyboard emits one spurious keyUp at t=0.711 (as seen in ptt-debug.log
    -- 2026-04-30 17:15:39.426, mid-hold, with no real release).
    local events = {}
    for t = 0, 3.0, 0.030 do events[#events + 1] = { t = t, kind = "down" } end
    events[#events + 1] = { t = 0.711, kind = "up" }    -- spurious
    events[#events + 1] = { t = 3.000, kind = "up" }    -- real release
    for i, e in ipairs(events) do e.seq = i end
    table.sort(events, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.seq < b.seq
    end)

    for _, e in ipairs(events) do
        advanceTo(e.t)
        if e.kind == "down" then keyDown() else keyUp() end
    end
    advanceTo(5.0)  -- let the final debounce expire

    return { starts = starts, stops = stops, cancels = cancels }
end

local expected = {
    -- The shipped ordering: one physical hold must yield exactly one session.
    fixed   = { starts = 1, stops = 1, cancels = 1 },
    -- The pre-fix ordering, kept as a baseline so this test fails loudly if the
    -- fast path is ever moved back above the debounce-cancel branch.
    current = { starts = 2, stops = 2, cancels = 0 },
}

local failed = false
for _, variant in ipairs({ "fixed", "current" }) do
    local r, e = runSim(variant), expected[variant]
    local ok = r.starts == e.starts and r.stops == e.stops and r.cancels == e.cancels
    if not ok then failed = true end
    print(string.format("%-8s starts=%d stops=%d debounce-cancels=%d   %s (expected %d/%d/%d)",
        variant, r.starts, r.stops, r.cancels, ok and "ok" or "MISMATCH",
        e.starts, e.stops, e.cancels))
end

print(failed and "\nFAIL" or "\nPASS - a single hold produces a single session")
os.exit(failed and 1 or 0)
