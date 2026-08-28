-- Regression tests for the Insert-key hold state machine (init.lua).
--
-- Models the keyDown/keyUp handler on a virtual clock so no audio, recording
-- or event-tap side effects are needed. Each scenario replays a real event
-- trace taken from ptt-debug.log.

local DEBOUNCE_MS          = 300
local HOLD_POLL_INTERVAL   = 0.25
local LOST_KEYUP_TIMEOUT   = 2.0
local MIN_REPEATS_TO_TRUST = 3

-- Returns a simulation of one physical hold.
--   variant: "fixed"  = the shipped handler
--            "legacy" = pre-fix ordering, kept as a baseline
--   events:  list of {t=seconds, kind="down"|"up"}
--   runTo:   how far to advance the clock after the last event
local function runSim(variant, events, runTo)
    local now, timers = 0, {}

    local function schedule(delay, fn, repeating)
        local t = { at = now + delay, fn = fn, every = repeating and delay or nil, dead = false }
        timers[#timers + 1] = t
        return { stop = function() t.dead = true end }
    end
    local function doAfter(delay, fn) return schedule(delay, fn, false) end
    local function doEvery(delay, fn) return schedule(delay, fn, true) end

    local function advanceTo(target)
        while true do
            local nxt
            for _, t in ipairs(timers) do
                if not t.dead and t.at <= target and (not nxt or t.at < nxt.at) then nxt = t end
            end
            if not nxt then break end
            now = nxt.at
            if nxt.every then nxt.at = nxt.at + nxt.every else nxt.dead = true end
            nxt.fn()
        end
        now = target
    end

    local insertKeyIsDown, keyUpDebounceTimer = false, nil
    local isRecording = false
    local starts, stops = 0, 0
    local repeatsThisHold, lastRepeatTime, holdWatchdog = 0, 0, nil
    local recoveredViaTimeout = false

    local function startRecording()
        if isRecording then return end
        isRecording = true; starts = starts + 1
    end
    local function stopRecording()
        if not isRecording then return end
        isRecording = false; stops = stops + 1
    end

    local function stopHoldWatchdog()
        if holdWatchdog then holdWatchdog:stop(); holdWatchdog = nil end
    end

    -- Detects a release whose keyUp never arrived, by noticing that macOS
    -- auto-repeat keyDowns have stopped. Only trusted once this hold has
    -- proven the keyboard actually auto-repeats.
    local function startHoldWatchdog()
        if variant == "legacy" then return end
        stopHoldWatchdog()
        holdWatchdog = doEvery(HOLD_POLL_INTERVAL, function()
            if not insertKeyIsDown then return end
            if repeatsThisHold < MIN_REPEATS_TO_TRUST then return end
            if (now - lastRepeatTime) > LOST_KEYUP_TIMEOUT then
                recoveredViaTimeout = true
                insertKeyIsDown = false
                if keyUpDebounceTimer then keyUpDebounceTimer:stop(); keyUpDebounceTimer = nil end
                stopHoldWatchdog()
                stopRecording()
            end
        end)
    end

    local function keyDown()
        if variant ~= "legacy" then
            if keyUpDebounceTimer then
                keyUpDebounceTimer:stop(); keyUpDebounceTimer = nil
                return
            end
            if insertKeyIsDown then
                repeatsThisHold = repeatsThisHold + 1
                lastRepeatTime = now
                return
            end
        else
            if insertKeyIsDown then return end
            if keyUpDebounceTimer then
                keyUpDebounceTimer:stop(); keyUpDebounceTimer = nil
                return
            end
        end
        insertKeyIsDown = true
        repeatsThisHold, lastRepeatTime = 0, now
        startHoldWatchdog()
        startRecording()
    end

    local function keyUp()
        if keyUpDebounceTimer then keyUpDebounceTimer:stop() end
        keyUpDebounceTimer = doAfter(DEBOUNCE_MS / 1000, function()
            keyUpDebounceTimer = nil
            insertKeyIsDown = false
            stopHoldWatchdog()
            stopRecording()
        end)
    end

    for i, e in ipairs(events) do e.seq = i end
    local ordered = {}
    for _, e in ipairs(events) do ordered[#ordered + 1] = e end
    table.sort(ordered, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.seq < b.seq
    end)

    for _, e in ipairs(ordered) do
        advanceTo(e.t)
        if e.kind == "down" then keyDown() else keyUp() end
    end
    advanceTo(runTo)

    return {
        starts = starts, stops = stops,
        stillRecording = isRecording,
        recoveredViaTimeout = recoveredViaTimeout,
    }
end

-- Auto-repeat keyDowns every 30ms for the duration of a physical hold.
local function repeats(from, to)
    local out = {}
    local t = from
    while t <= to + 1e-9 do
        out[#out + 1] = { t = t, kind = "down" }
        t = t + 0.030
    end
    return out
end

local SCENARIOS = {
    {
        name = "spurious mid-hold keyUp",
        -- ptt-debug.log 2026-04-30 17:15:39.426: a keyUp arrives mid-hold with
        -- no real release. Must not end the session.
        events = (function()
            local e = repeats(0, 3.0)
            e[#e + 1] = { t = 0.711, kind = "up" }
            e[#e + 1] = { t = 3.000, kind = "up" }
            return e
        end)(),
        runTo = 6.0,
        expect = { starts = 1, stops = 1, stillRecording = false },
    },
    {
        name = "lost keyUp on release",
        -- ptt-debug.log 2026-08-22 14:58:29 session 4: the release keyUp never
        -- arrived. Auto-repeat simply stops. The session must still end.
        events = repeats(0, 3.0),
        runTo = 10.0,
        expect = { starts = 1, stops = 1, stillRecording = false, recoveredViaTimeout = true },
    },
}

local failed = false
for _, sc in ipairs(SCENARIOS) do
    print("scenario: " .. sc.name)
    for _, variant in ipairs({ "fixed", "legacy" }) do
        local r = runSim(variant, sc.events, sc.runTo)
        local ok = true
        if variant == "fixed" then
            for k, want in pairs(sc.expect) do
                if r[k] ~= want then ok = false end
            end
            if not ok then failed = true end
        end
        print(string.format("  %-7s starts=%d stops=%d stillRecording=%-5s recovered=%-5s %s",
            variant, r.starts, r.stops, tostring(r.stillRecording),
            tostring(r.recoveredViaTimeout),
            variant == "fixed" and (ok and "PASS" or "FAIL") or "(baseline)"))
    end
end

print(failed and "\nFAIL" or "\nPASS - every hold ends its session, with or without a keyUp")
os.exit(failed and 1 or 0)
