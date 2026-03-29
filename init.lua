-- ==========================================================================
-- Push-to-Talk for Claude Code
-- Hold Insert to speak → chunk-based transcription → clipboard paste
-- ==========================================================================

require("hs.ipc")  -- enable CLI debugging via `hs` command

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local WHISPER_HOST          = "127.0.0.1"
local WHISPER_PORT          = 7178
local WHISPER_URL           = "http://" .. WHISPER_HOST .. ":" .. WHISPER_PORT
local INFERENCE_ENDPOINT    = WHISPER_URL .. "/inference"

local REC_BINARY            = "/opt/homebrew/bin/rec"
local PERL_BINARY           = "/usr/bin/perl"
local WORD_FIXES_FILE       = os.getenv("HOME") .. "/.config/ptt/word-fixes.pl"

local RECORDING_DIR         = (os.getenv("TMPDIR") or "/tmp/") .. "ptt"
local MIN_CHUNK_BYTES       = 8000    -- ~0.25s at 16kHz/16-bit/mono
local SILENCE_DURATION      = "0.4"   -- seconds of silence to end a phrase (catches clause pauses)
local SILENCE_THRESHOLD     = "1%"    -- energy floor for silence detection
local MAX_CHUNK_SECONDS     = 5       -- force-split continuous speech every 5s
local MAX_SESSION_SECONDS   = 120     -- watchdog: force-stop entire session
local CLIPBOARD_RESTORE_MS  = 400     -- delay before restoring clipboard (ms)

local INSERT_KEY_CODE       = 114     -- macOS "Help/Insert" key

local ENABLE_SOUNDS         = true    -- set false to disable audio feedback
local LOG_FILE              = os.getenv("HOME") .. "/.config/ptt/ptt-debug.log"

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------

local logFileHandle = nil

local function openLogFile()
    logFileHandle = io.open(LOG_FILE, "a")
    if logFileHandle then
        logFileHandle:setvbuf("line")  -- flush after every line
    end
end

local function log(level, message)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local ms = math.floor((hs.timer.secondsSinceEpoch() % 1) * 1000)
    local line = string.format("[%s.%03d] [%s] %s", timestamp, ms, level, message)
    print(line)  -- Hammerspoon console
    if logFileHandle then
        logFileHandle:write(line .. "\n")
    end
end

local function logDebug(message) log("DEBUG", message) end
local function logInfo(message)  log("INFO",  message) end
local function logWarn(message)  log("WARN",  message) end
local function logError(message) log("ERROR", message) end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local isRecording           = false
local stopRequested         = false
local cancelRequested       = false
local currentRecordingTask  = nil
local chunkCount            = 0
local sessionId             = 0       -- increments per session, gates stale callbacks
local watchdogTimer         = nil
local savedClipboard        = nil
local activeTranscriptions  = 0

-- Ordered paste queue: ensures phrases appear in recording order
-- Uses `false` as sentinel for skipped/discarded chunks
local pasteQueue            = {}      -- chunkIndex → text or false (skipped)
local nextPasteIndex        = 1
local pasteInProgress       = false
local pendingPastes         = {}      -- sequential buffer of ready texts

-- Track whether we've pasted anything (for inter-phrase spacing)
local hasPastedInSession    = false
local lastPasteTimestamp    = 0       -- epoch seconds of last paste, for inter-session spacing

-- Context carry-forward: last transcription text is used as prompt for next chunk
-- This tells Whisper "you're continuing this sentence" so it doesn't re-capitalize
-- or add false periods at chunk boundaries
local lastTranscriptionText = ""

-- Timing
local chunkStartTimes       = {}      -- chunkIndex → epoch timestamp when recording started

-- ---------------------------------------------------------------------------
-- Menu Bar (colored dot via hs.canvas)
-- ---------------------------------------------------------------------------

local menuBar = hs.menubar.new()

local function currentUID()
    local output = hs.execute("id -u")
    return output:gsub("%s+", "")
end

local function makeMenuBarIcon(color)
    local canvas = hs.canvas.new({ x = 0, y = 0, w = 18, h = 18 })
    canvas[1] = {
        type = "circle",
        center = { x = 9, y = 9 },
        radius = 5,
        fillColor = color,
        action = "fill",
    }
    local image = canvas:imageFromCanvas()
    canvas:delete()
    return image
end

local COLOR_GREEN  = { red = 0.30, green = 0.78, blue = 0.40, alpha = 1.0 }
local COLOR_RED    = { red = 0.92, green = 0.26, blue = 0.24, alpha = 1.0 }
local COLOR_ORANGE = { red = 0.95, green = 0.65, blue = 0.15, alpha = 1.0 }
local COLOR_GRAY   = { red = 0.55, green = 0.55, blue = 0.55, alpha = 1.0 }

local function setMenuBarState(color, tooltip, statusText)
    menuBar:setIcon(makeMenuBarIcon(color))
    menuBar:setTitle(nil)
    menuBar:setTooltip(tooltip)
    menuBar:setMenu({
        { title = statusText, disabled = true },
        { title = "-" },
        { title = "Voice: say 'scratch that' to undo last phrase", disabled = true },
        { title = "Cancel: press Escape while recording", disabled = true },
        { title = "-" },
        { title = "Restart Whisper Server", fn = function()
            hs.execute("launchctl kickstart -k gui/" .. currentUID() .. "/com.ptt.whisper-server")
            hs.alert.show("Restarting whisper server…", 2)
            logInfo("User requested whisper server restart")
        end },
        { title = "Open Word Fixes", fn = function()
            hs.execute("open -a TextEdit '" .. WORD_FIXES_FILE .. "'")
        end },
        { title = "Show PTT Debug Log", fn = function()
            hs.execute("open -a Console '" .. LOG_FILE .. "'")
        end },
        { title = "Show Server Log", fn = function()
            hs.execute("open -a Console '" .. os.getenv("HOME") .. "/.config/ptt/whisper-server.log'")
        end },
        { title = "-" },
        { title = "Sounds: " .. (ENABLE_SOUNDS and "On" or "Off"), fn = function()
            ENABLE_SOUNDS = not ENABLE_SOUNDS
            hs.alert.show("Sounds " .. (ENABLE_SOUNDS and "enabled" or "disabled"), 1)
        end },
        { title = "Reload Hammerspoon", fn = hs.reload },
    })
end

local function showIdle()
    setMenuBarState(COLOR_GREEN, "PTT: Ready (Insert to speak)", "Status: Idle")
end

local function showRecording()
    setMenuBarState(COLOR_RED, "PTT: Recording…", "Status: Recording")
end

local function showTranscribing()
    setMenuBarState(COLOR_ORANGE, "PTT: Transcribing…", "Status: Transcribing")
end

local function showServerDown()
    setMenuBarState(COLOR_GRAY, "PTT: Whisper server offline", "Status: Server Offline")
end

-- ---------------------------------------------------------------------------
-- Floating Recording Indicator
-- ---------------------------------------------------------------------------

local floatingIndicator = nil
local durationTimer = nil
local recordingStartTime = nil

local function showFloatingIndicator()
    if floatingIndicator then floatingIndicator:delete() end

    local screen = hs.screen.mainScreen()
    local screenFrame = screen:frame()

    local indicatorWidth = 160
    local indicatorHeight = 32
    local indicatorX = screenFrame.x + (screenFrame.w - indicatorWidth) / 2
    local indicatorY = screenFrame.y + 8

    floatingIndicator = hs.canvas.new({
        x = indicatorX, y = indicatorY,
        w = indicatorWidth, h = indicatorHeight,
    })

    floatingIndicator[1] = {
        type = "rectangle",
        roundedRectRadii = { xRadius = 12, yRadius = 12 },
        fillColor = { red = 0.15, green = 0.15, blue = 0.15, alpha = 0.85 },
        action = "fill",
    }

    floatingIndicator[2] = {
        type = "circle",
        center = { x = 20, y = 16 },
        radius = 5,
        fillColor = COLOR_RED,
        action = "fill",
    }

    floatingIndicator[3] = {
        type = "text",
        text = hs.styledtext.new("Recording 0:00", {
            font = { name = ".AppleSystemUIFont", size = 13 },
            color = { white = 1.0 },
            paragraphStyle = { alignment = "left" },
        }),
        frame = { x = "20%", y = "10%", w = "75%", h = "80%" },
    }

    floatingIndicator:level(hs.canvas.windowLevels.overlay)
    floatingIndicator:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    floatingIndicator:show()

    recordingStartTime = hs.timer.secondsSinceEpoch()

    durationTimer = hs.timer.doEvery(0.5, function()
        if floatingIndicator and recordingStartTime then
            local elapsed = hs.timer.secondsSinceEpoch() - recordingStartTime
            local minutes = math.floor(elapsed / 60)
            local seconds = math.floor(elapsed % 60)
            local durationText = string.format("Recording %d:%02d", minutes, seconds)

            floatingIndicator[3] = {
                type = "text",
                text = hs.styledtext.new(durationText, {
                    font = { name = ".AppleSystemUIFont", size = 13 },
                    color = { white = 1.0 },
                    paragraphStyle = { alignment = "left" },
                }),
                frame = { x = "20%", y = "10%", w = "75%", h = "80%" },
            }
        end
    end)
end

local function hideFloatingIndicator()
    if durationTimer then
        durationTimer:stop()
        durationTimer = nil
    end
    if floatingIndicator then
        floatingIndicator:delete()
        floatingIndicator = nil
    end
    recordingStartTime = nil
end

-- ---------------------------------------------------------------------------
-- Server Health Check
-- ---------------------------------------------------------------------------

local serverIsUp = false

local function checkServerHealth()
    if isRecording then return end

    hs.http.asyncGet(WHISPER_URL, nil, function(statusCode, _body, _headers)
        local wasUp = serverIsUp
        if statusCode and statusCode >= 200 and statusCode < 400 then
            serverIsUp = true
            if not wasUp then
                logInfo("Whisper server is UP (status " .. tostring(statusCode) .. ")")
                if not isRecording and activeTranscriptions == 0 then
                    showIdle()
                end
            end
        else
            serverIsUp = false
            if wasUp then
                logWarn("Whisper server is DOWN (status " .. tostring(statusCode or "nil") .. ")")
            end
            if not isRecording and activeTranscriptions == 0 then
                showServerDown()
            end
        end
    end)
end

local healthCheckTimer = hs.timer.doEvery(10, checkServerHealth)

-- ---------------------------------------------------------------------------
-- Audio Feedback
-- ---------------------------------------------------------------------------

local function playStartSound()
    if not ENABLE_SOUNDS then return end
    local sound = hs.sound.getByName("Tink")
    if sound then sound:play() end
end

local function playStopSound()
    if not ENABLE_SOUNDS then return end
    local sound = hs.sound.getByName("Pop")
    if sound then sound:play() end
end

local function playErrorSound()
    if not ENABLE_SOUNDS then return end
    local sound = hs.sound.getByName("Basso")
    if sound then sound:play() end
end

-- ---------------------------------------------------------------------------
-- Clipboard Paste (ordered queue)
-- ---------------------------------------------------------------------------

local clipboardRestoreRetries = 0
local MAX_CLIPBOARD_RESTORE_RETRIES = 10

local function restoreClipboard()
    hs.timer.doAfter(CLIPBOARD_RESTORE_MS / 1000, function()
        if savedClipboard then
            if pasteInProgress or #pendingPastes > 0 then
                clipboardRestoreRetries = clipboardRestoreRetries + 1
                if clipboardRestoreRetries >= MAX_CLIPBOARD_RESTORE_RETRIES then
                    logWarn("Clipboard restore: gave up after " .. MAX_CLIPBOARD_RESTORE_RETRIES .. " retries, restoring now")
                    pasteInProgress = false  -- unstick
                else
                    logDebug("Clipboard restore deferred — paste queue not drained")
                    restoreClipboard()
                    return
                end
            end
            hs.pasteboard.setContents(savedClipboard)
            savedClipboard = nil
            clipboardRestoreRetries = 0
            logDebug("Clipboard restored")
        end
    end)
end

local function flushPasteQueue()
    if pasteInProgress then return end
    if #pendingPastes == 0 then return end

    pasteInProgress = true
    local text = table.remove(pendingPastes, 1)

    lastPasteTimestamp = os.time()

    logInfo("PASTE: \"" .. text .. "\" (" .. #text .. " chars)")

    hs.pasteboard.setContents(text)
    hs.eventtap.keyStroke({"cmd"}, "v")

    hs.timer.doAfter(0.15, function()
        pasteInProgress = false
        flushPasteQueue()
    end)
end

local function enqueuePasteOrdered(chunkIndex, text)
    pasteQueue[chunkIndex] = text

    while pasteQueue[nextPasteIndex] ~= nil do
        local entry = pasteQueue[nextPasteIndex]
        if entry and entry ~= false then
            -- Prepend space between phrases (within and across sessions)
            -- This runs in paste-order (not arrival-order) so spacing is correct
            -- even when transcriptions complete out of order
            if hasPastedInSession or (os.time() - lastPasteTimestamp) < 10 then
                entry = " " .. entry
            end
            hasPastedInSession = true
            table.insert(pendingPastes, entry)
        end
        pasteQueue[nextPasteIndex] = nil
        nextPasteIndex = nextPasteIndex + 1
    end

    flushPasteQueue()
end

-- ---------------------------------------------------------------------------
-- "Scratch That" — undo the last pasted phrase via Cmd+Z
-- ---------------------------------------------------------------------------

local function scratchLastPhrase()
    logInfo("SCRATCH THAT — sending Cmd+Z")
    hs.eventtap.keyStroke({"cmd"}, "z")
end

-- ---------------------------------------------------------------------------
-- Word Fixes
-- ---------------------------------------------------------------------------

local function applyWordFixes(text)
    if not text or text == "" then return text end
    if not hs.fs.attributes(WORD_FIXES_FILE) then return text end

    local inputPath = RECORDING_DIR .. "/fix-input.tmp"
    local file = io.open(inputPath, "w")
    if not file then return text end
    file:write(text)
    file:close()

    local output, status = hs.execute(PERL_BINARY .. " " .. WORD_FIXES_FILE .. " < '" .. inputPath .. "'")
    os.remove(inputPath)

    if status and output and output:match("%S") then
        local fixed = output:gsub("%s+$", "")
        if fixed ~= text then
            logDebug("Word fix: \"" .. text .. "\" → \"" .. fixed .. "\"")
        end
        return fixed
    end
    return text
end

local function validateWordFixes()
    if not hs.fs.attributes(WORD_FIXES_FILE) then
        logWarn("Word fixes file not found: " .. WORD_FIXES_FILE)
        return
    end
    local output, status = hs.execute(PERL_BINARY .. " -c '" .. WORD_FIXES_FILE .. "' 2>&1")
    if not status then
        logError("word-fixes.pl has syntax errors: " .. (output or ""))
        hs.alert.show("PTT: word-fixes.pl has syntax errors!", 5)
    else
        logInfo("word-fixes.pl validated OK")
    end
end

-- ---------------------------------------------------------------------------
-- Transcription
-- ---------------------------------------------------------------------------

local function sessionFinished()
    if not isRecording and activeTranscriptions == 0 then
        logInfo("Session complete — all transcriptions finished")
        showIdle()
        restoreClipboard()
    end
end

local function transcribeChunk(chunkFile, chunkIndex, expectedSessionId)
    local transcribeStartTime = hs.timer.secondsSinceEpoch()

    -- Gate: ignore results from a stale session
    if expectedSessionId ~= sessionId then
        logDebug("Chunk " .. chunkIndex .. ": stale session (expected " .. expectedSessionId .. ", current " .. sessionId .. "), discarding")
        os.remove(chunkFile)
        activeTranscriptions = activeTranscriptions - 1
        return
    end

    -- Gate: session was cancelled
    if cancelRequested then
        logDebug("Chunk " .. chunkIndex .. ": session cancelled, discarding")
        os.remove(chunkFile)
        activeTranscriptions = activeTranscriptions - 1
        enqueuePasteOrdered(chunkIndex, false)
        sessionFinished()
        return
    end

    -- Check file size
    local attributes = hs.fs.attributes(chunkFile)
    local fileSize = attributes and attributes.size or 0
    local audioDurationSeconds = fileSize > 44 and (fileSize - 44) / 32000 or 0

    logDebug(string.format("Chunk %d: file=%s size=%d bytes (%.1fs audio)",
        chunkIndex, chunkFile, fileSize, audioDurationSeconds))

    -- Debounce: skip tiny files (< ~0.5s of audio)
    if fileSize < MIN_CHUNK_BYTES then
        logDebug(string.format("Chunk %d: too small (%d < %d bytes), skipping", chunkIndex, fileSize, MIN_CHUNK_BYTES))
        os.remove(chunkFile)
        activeTranscriptions = activeTranscriptions - 1
        enqueuePasteOrdered(chunkIndex, false)
        sessionFinished()
        return
    end

    -- Carry forward the previous chunk's transcription as a prompt so Whisper
    -- knows it's continuing a sentence (preserves capitalization and punctuation)
    local promptFile = chunkFile .. ".prompt"
    local contextPrompt = lastTranscriptionText or ""

    -- Write prompt to a temp file — avoids shell escaping nightmares
    -- curl -F 'prompt=<filepath' reads the file contents as the field value
    if contextPrompt ~= "" then
        local promptHandle = io.open(promptFile, "w")
        if promptHandle then
            promptHandle:write(contextPrompt)
            promptHandle:close()
        end
    end

    -- Build curl command with context prompt
    local curlCommand
    if contextPrompt ~= "" and hs.fs.attributes(promptFile) then
        curlCommand = string.format(
            "curl -s -X POST '%s' -F 'file=@%s' -F 'response_format=text' -F 'language=en' -F 'prompt=<%s' 2>&1",
            INFERENCE_ENDPOINT, chunkFile, promptFile
        )
    else
        curlCommand = string.format(
            "curl -s -X POST '%s' -F 'file=@%s' -F 'response_format=text' -F 'language=en' 2>&1",
            INFERENCE_ENDPOINT, chunkFile
        )
    end

    logDebug(string.format("Chunk %d: sending to whisper (context: \"%s\")",
        chunkIndex, contextPrompt ~= "" and contextPrompt:sub(1, 80) or "none"))

    hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
        local elapsed = hs.timer.secondsSinceEpoch() - transcribeStartTime
        os.remove(chunkFile)
        os.remove(promptFile)

        -- Gate: check session is still current
        if expectedSessionId ~= sessionId then
            logDebug("Chunk " .. chunkIndex .. ": stale session after transcription, discarding")
            activeTranscriptions = activeTranscriptions - 1
            return
        end

        activeTranscriptions = activeTranscriptions - 1

        if cancelRequested then
            logDebug("Chunk " .. chunkIndex .. ": cancelled after transcription")
            enqueuePasteOrdered(chunkIndex, false)
            sessionFinished()
            return
        end

        if exitCode == 0 and stdout and stdout:match("%S") then
            local rawText = stdout:gsub("^%s+", ""):gsub("%s+$", "")

            logInfo(string.format("Chunk %d: transcribed in %.1fs → \"%s\"",
                chunkIndex, elapsed, rawText))

            -- Filter common whisper hallucinations on near-silence
            local lowerText = rawText:lower()
            if lowerText == "thank you." or lowerText == "thanks for watching."
                or lowerText == "subscribe" or lowerText == "you"
                or lowerText == "thank you for watching."
                or lowerText == "thanks for watching!"
                or lowerText == "(silence)" or lowerText == "[silence]"
                or lowerText == "..." or #rawText < 2 then
                logWarn("Chunk " .. chunkIndex .. ": hallucination discarded: \"" .. rawText .. "\"")
                enqueuePasteOrdered(chunkIndex, false)
            else
                -- Save raw transcription as context for the NEXT chunk
                -- This is BEFORE word fixes, so Whisper sees natural text as prompt
                lastTranscriptionText = rawText

                local text = applyWordFixes(rawText)
                if text and text ~= "" then
                    if text:lower():match("^scratch that%.?$") then
                        scratchLastPhrase()
                        enqueuePasteOrdered(chunkIndex, false)
                    else
                        enqueuePasteOrdered(chunkIndex, text)
                    end
                else
                    logDebug("Chunk " .. chunkIndex .. ": empty after word fixes")
                    enqueuePasteOrdered(chunkIndex, false)
                end
            end
        else
            logError(string.format("Chunk %d: transcription failed (exit=%d) stderr=%s",
                chunkIndex, exitCode or -1, stderr or "nil"))
            playErrorSound()
            enqueuePasteOrdered(chunkIndex, false)
            checkServerHealth()
        end

        sessionFinished()
    end, {"-c", curlCommand}):start()
end

-- ---------------------------------------------------------------------------
-- Recording (single-process, multi-file via sox newfile:restart)
-- One `rec` process runs for the entire session. Sox splits on silence and
-- writes numbered chunk files. A polling timer detects new files and sends
-- them to transcription. This eliminates CoreAudio reinit between chunks,
-- which caused audible clicking/popping artifacts.
-- ---------------------------------------------------------------------------

local chunkPollTimer        = nil
local lastProcessedChunk    = 0       -- highest chunk number we've processed
local recBaseFile           = ""      -- base filename for sox newfile output

-- Sox newfile:restart names files: base001.wav, base002.wav, base003.wav, ...
-- (the un-numbered base file is never created)
local function chunkFilePath(chunkNumber)
    return recBaseFile:gsub("%.wav$", string.format("%03d.wav", chunkNumber))
end

local function processNewChunks()
    if cancelRequested then return end

    local currentSessionId = sessionId

    -- Scan for new chunk files
    while true do
        local nextChunk = lastProcessedChunk + 1
        local candidatePath = chunkFilePath(nextChunk)
        local attr = hs.fs.attributes(candidatePath)

        if not attr then break end -- no more files yet

        -- The file exists, but is sox still writing to it?
        -- If the NEXT file exists, this one is definitely complete.
        -- If rec has exited, this one is also complete.
        -- Otherwise, wait for next poll cycle.
        local nextNextPath = chunkFilePath(nextChunk + 1)
        local recStillRunning = currentRecordingTask and currentRecordingTask:isRunning()
        local nextFileExists = hs.fs.attributes(nextNextPath) ~= nil

        if not nextFileExists and recStillRunning then
            -- This file might still be open for writing — wait
            break
        end

        -- This chunk is complete — process it
        lastProcessedChunk = nextChunk
        chunkCount = nextChunk

        local fileSize = attr.size or 0
        local audioDurationSeconds = fileSize > 44 and (fileSize - 44) / 32000 or 0

        logDebug(string.format("Chunk %d: detected file=%s size=%d bytes (%.1fs audio)",
            nextChunk, candidatePath, fileSize, audioDurationSeconds))

        if fileSize < MIN_CHUNK_BYTES then
            logDebug(string.format("Chunk %d: too small (%d < %d bytes), skipping",
                nextChunk, fileSize, MIN_CHUNK_BYTES))
            os.remove(candidatePath)
            enqueuePasteOrdered(nextChunk, false)
        else
            activeTranscriptions = activeTranscriptions + 1
            transcribeChunk(candidatePath, nextChunk, currentSessionId)
        end
    end
end

local function startRecordingProcess()
    local currentSessionId = sessionId
    recBaseFile = string.format("%s/chunk-%d.wav", RECORDING_DIR, currentSessionId)
    lastProcessedChunk = 0

    logDebug("Starting single rec process → " .. recBaseFile)

    -- Single rec process for the entire session.
    -- sox `: newfile : restart` splits on silence into numbered files
    -- without reopening CoreAudio between chunks.
    currentRecordingTask = hs.task.new(REC_BINARY, function(exitCode, _stdout, stderr)
        currentRecordingTask = nil

        logInfo(string.format("rec process exited (exit=%d, stderr=%s)",
            exitCode or -1, (stderr and stderr ~= "") and stderr or "none"))

        -- Process any remaining chunk files
        processNewChunks()

        -- Session teardown (if not already torn down by stopRecording)
        if isRecording then
            isRecording = false
            hideFloatingIndicator()
        end

        if chunkPollTimer then
            chunkPollTimer:stop()
            chunkPollTimer = nil
        end

        if activeTranscriptions > 0 then
            showTranscribing()
        else
            sessionFinished()
        end

    end, {
        "-q",
        "-r", "16000", "-c", "1", "-b", "16",
        recBaseFile,
        "silence", "1", "0.01", "0.1%",
        "1", SILENCE_DURATION, SILENCE_THRESHOLD,
        "trim", "0", tostring(MAX_CHUNK_SECONDS),
        ":", "newfile", ":", "restart",
    })

    if not currentRecordingTask:start() then
        logError("Failed to start rec process")
        hs.alert.show("PTT Error: Failed to start recording", 3)
        playErrorSound()
        isRecording = false
        hideFloatingIndicator()
        showIdle()
        return
    end

    -- Poll for new chunk files every 200ms
    chunkPollTimer = hs.timer.doEvery(0.2, function()
        if not cancelRequested then
            processNewChunks()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Start / Stop / Cancel
-- ---------------------------------------------------------------------------

local function killOrphanedRecProcesses()
    hs.execute("pkill -x rec 2>/dev/null", true)
end

local function startRecording()
    if isRecording then
        logDebug("startRecording: already recording, ignoring")
        return
    end

    if not serverIsUp then
        logWarn("startRecording: server is down, refusing to record")
        hs.alert.show("PTT: Whisper server is offline", 2)
        playErrorSound()
        return
    end

    killOrphanedRecProcesses()

    sessionId = sessionId + 1

    logInfo(string.format("=== SESSION %d START ===", sessionId))

    isRecording = true
    stopRequested = false
    cancelRequested = false
    chunkCount = 0
    nextPasteIndex = 1
    pasteQueue = {}
    pendingPastes = {}
    pasteInProgress = false
    hasPastedInSession = false
    lastTranscriptionText = ""  -- reset context carry-forward
    chunkStartTimes = {}

    savedClipboard = hs.pasteboard.getContents()

    escapeHotkey:enable()
    showRecording()
    showFloatingIndicator()
    playStartSound()

    watchdogTimer = hs.timer.doAfter(MAX_SESSION_SECONDS, function()
        if isRecording then
            logWarn("Session " .. sessionId .. ": watchdog fired at " .. MAX_SESSION_SECONDS .. "s")
            hs.alert.show("PTT: Max duration reached", 2)
            stopRequested = true
            if currentRecordingTask and currentRecordingTask:isRunning() then
                currentRecordingTask:terminate()
            end
        end
    end)

    startRecordingProcess()
end

local function stopRecording()
    if not isRecording then return end

    logInfo(string.format("=== SESSION %d STOP (key released) === chunks=%d activeTranscriptions=%d",
        sessionId, chunkCount, activeTranscriptions))

    stopRequested = true
    playStopSound()

    if watchdogTimer then
        watchdogTimer:stop()
        watchdogTimer = nil
    end

    -- SIGTERM the rec process so it flushes and finalizes the WAV header.
    -- The rec exit callback handles final chunk processing and teardown.
    if currentRecordingTask and currentRecordingTask:isRunning() then
        logDebug("Sending SIGTERM to rec process")
        currentRecordingTask:terminate()
    end

    if chunkPollTimer then
        chunkPollTimer:stop()
        chunkPollTimer = nil
    end

    escapeHotkey:disable()
    hideFloatingIndicator()
    isRecording = false
    -- Note: don't call processNewChunks() here — rec hasn't flushed yet.
    -- The rec exit callback will process remaining files.
end

local function cancelRecording()
    if not isRecording and activeTranscriptions == 0 then return end

    logInfo(string.format("=== SESSION %d CANCELLED === chunks=%d activeTranscriptions=%d",
        sessionId, chunkCount, activeTranscriptions))

    cancelRequested = true
    stopRequested = true

    escapeHotkey:disable()

    if watchdogTimer then
        watchdogTimer:stop()
        watchdogTimer = nil
    end

    if chunkPollTimer then
        chunkPollTimer:stop()
        chunkPollTimer = nil
    end

    if currentRecordingTask and currentRecordingTask:isRunning() then
        currentRecordingTask:terminate()
    end

    pendingPastes = {}
    pasteQueue = {}

    hideFloatingIndicator()
    isRecording = false

    if savedClipboard then
        hs.pasteboard.setContents(savedClipboard)
        savedClipboard = nil
    end

    hs.alert.show("PTT: Cancelled", 1)
    playErrorSound()

    if activeTranscriptions == 0 then
        showIdle()
    else
        showTranscribing()
    end
end

-- ---------------------------------------------------------------------------
-- Global Hotkeys (hs.hotkey — press/release, no key repeat)
--
-- hs.hotkey fires pressedfn once on key-down and releasedfn once on key-up,
-- regardless of hold duration or system key repeat rate. This avoids the
-- macOS key repeat flooding that caused rapid start/stop cycling with
-- hs.eventtap (Hammerspoon issues #1179, #1308).
-- Wooting debounce retained for hardware-level rapid trigger jitter.
-- ---------------------------------------------------------------------------

local DEBOUNCE_MS        = 300     -- ms to wait after release before stopping (Wooting analog jitter)
local keyUpDebounceTimer = nil

-- Escape hotkey — only enabled during recording, disabled otherwise so
-- Escape passes through to other apps normally
local escapeHotkey = hs.hotkey.new({}, "escape", function()
    cancelRecording()
end)

-- Resolve Insert key name from keyCode (114 → "help" on macOS)
local insertKeyName = hs.keycodes.map[INSERT_KEY_CODE]
if not insertKeyName then
    logError("No key name found for keyCode " .. INSERT_KEY_CODE .. ", falling back to 'help'")
    insertKeyName = "help"
end

local insertHotkey = hs.hotkey.bind({}, insertKeyName,
    -- pressedfn: fires once on key down (no repeats)
    function()
        -- Cancel any pending debounced stop (Wooting rapid trigger jitter)
        if keyUpDebounceTimer then
            keyUpDebounceTimer:stop()
            keyUpDebounceTimer = nil
            logDebug("Debounce: cancelled pending stop (key re-pressed)")
            return
        end
        logDebug("Insert key pressed (hs.hotkey)")
        startRecording()
    end,
    -- releasedfn: fires once on key up
    function()
        -- Debounce for Wooting analog keyboards with rapid trigger
        if keyUpDebounceTimer then
            keyUpDebounceTimer:stop()
        end
        keyUpDebounceTimer = hs.timer.doAfter(DEBOUNCE_MS / 1000, function()
            keyUpDebounceTimer = nil
            logDebug("Insert key released (debounced)")
            stopRecording()
        end)
    end,
    nil  -- no repeatfn — all key repeat events are suppressed
)

-- ---------------------------------------------------------------------------
-- Hotkey Watchdog
-- macOS can silently disable hotkeys (accessibility revocation, sleep/wake).
-- This timer detects dead hotkeys and restarts them.
-- ---------------------------------------------------------------------------

local function restartHotkey()
    logWarn("Insert hotkey is disabled — attempting restart")
    insertHotkey:disable()
    insertHotkey:enable()

    if insertHotkey:isEnabled() then
        logInfo("Insert hotkey restarted successfully")
        hs.alert.show("PTT: Hotkey restored", 2)
    else
        logError("Insert hotkey restart FAILED — accessibility permission likely revoked")
        hs.alert.show("⚠ PTT: Hotkey broken — check Accessibility permissions", 5)
    end
end

local hotkeyWatchdog = hs.timer.new(30, function()
    if not insertHotkey:isEnabled() then
        restartHotkey()
    end
end)

-- Re-check hotkey on wake from sleep (macOS often kills event taps across sleep cycles)
local sleepWatcher = hs.caffeinate.watcher.new(function(eventType)
    if eventType == hs.caffeinate.watcher.systemDidWake then
        logInfo("System woke from sleep — checking hotkey health")
        -- Short delay: accessibility subsystem needs a moment after wake
        hs.timer.doAfter(2, function()
            if not insertHotkey:isEnabled() then
                restartHotkey()
            else
                logDebug("Insert hotkey healthy after wake")
            end
        end)
    end
end)

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

openLogFile()
logInfo("========================================")
logInfo("PTT initializing")
logInfo("  Recording dir: " .. RECORDING_DIR)
logInfo("  Whisper server: " .. WHISPER_URL)
logInfo("  Rec binary: " .. REC_BINARY)
logInfo("  Word fixes: " .. WORD_FIXES_FILE)
logInfo("  Insert key code: " .. INSERT_KEY_CODE)
logInfo("  Silence threshold: " .. SILENCE_THRESHOLD .. " for " .. SILENCE_DURATION .. "s (clause-level splitting)")
logInfo("  Min chunk bytes: " .. MIN_CHUNK_BYTES)
logInfo("  Max chunk seconds: " .. MAX_CHUNK_SECONDS)
logInfo("========================================")

hs.execute("mkdir -p '" .. RECORDING_DIR .. "' && chmod 700 '" .. RECORDING_DIR .. "'")
hs.execute("find '" .. RECORDING_DIR .. "' -name 'chunk-*.wav' -mmin +10 -delete 2>/dev/null")
killOrphanedRecProcesses()
validateWordFixes()

showServerDown()
-- insertHotkey is already enabled by hs.hotkey.bind()
hotkeyWatchdog:start()
sleepWatcher:start()
checkServerHealth()

logInfo("PTT ready — waiting for Insert key")
hs.alert.show("PTT loaded — hold Insert to speak", 3)
