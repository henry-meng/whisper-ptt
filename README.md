# whisper-ptt

Fully local push-to-talk voice transcription for macOS. Hold a key, speak, release — transcribed text is pasted at your cursor. No cloud APIs, no network latency, no data leaves your machine.

Built on [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (server mode), [Hammerspoon](https://www.hammerspoon.org/), and [SoX](https://sox.sourceforge.net/).

## How it works

```
Insert key held → sox records audio in chunks (split on 0.4s silence or 5s max)
    → each chunk sent to local whisper.cpp server (HTTP POST)
    → transcription passed through word-fixes.pl
    → text pasted via Cmd+V at cursor position
```

Chunks are transcribed in parallel with ongoing recording, so text appears phrase-by-phrase as you speak — not all at once when you stop.

## Features

- **Push-to-talk**: hold Insert key to record, release to stop
- **Chunk-based transcription**: phrases appear as you finish them (split on 0.4s silence)
- **Context carry-forward**: previous chunk's text is passed as a prompt to the next chunk, so mid-sentence pauses don't break capitalization or punctuation
- **Whisper auto-punctuation**: periods, commas, question marks inserted naturally from speech prosody
- **Voice commands**: say "new line", "new paragraph", "open quote", "close quote", "colon", "semicolon", "em dash", "ellipsis", "open paren"/"close paren", etc.
- **"Scratch that"**: say "scratch that" to undo the last pasted phrase (sends Cmd+Z)
- **Cancel**: press Escape while recording to discard everything
- **Hallucination filtering**: common whisper hallucinations ("Thank you.", "Thanks for watching.") are automatically discarded
- **Custom vocabulary**: edit `word-fixes.pl` to correct domain-specific misrecognitions
- **Menu bar indicator**: colored dot shows status (green=ready, red=recording, orange=transcribing, gray=server offline)
- **Floating recording pill**: shows recording duration at top of screen
- **Audio feedback**: start/stop sounds (configurable, can be disabled)
- **Clipboard preservation**: your clipboard contents are saved before recording and restored after pasting
- **Event tap watchdog**: automatically restarts the hotkey listener if macOS silently kills it (sleep/wake, accessibility changes)
- **Boot persistent**: whisper server runs as a LaunchAgent, Hammerspoon launches at login

## Requirements

- macOS 14+ (Sonoma or later) on Apple Silicon
- [Homebrew](https://brew.sh)
- [Hammerspoon](https://www.hammerspoon.org/) (with Accessibility permissions granted)
- A keyboard with an Insert key (default hotkey is Insert/Help, keyCode 114)

## Quick install

```bash
git clone https://github.com/yourusername/whisper-ptt.git
cd whisper-ptt
chmod +x install.sh
./install.sh
```

The install script will:

1. Install `whisper-cpp` and `sox` via Homebrew (if not already installed)
2. Download the Whisper large-v3-turbo model (~1.5 GB) to `~/.local/share/whisper/`
3. Install `word-fixes.pl` to `~/.config/ptt/`
4. Install `init.lua` to `~/.hammerspoon/` (with backup/append options if one exists)
5. Install and start the whisper-server LaunchAgent
6. Reload Hammerspoon

## Manual install

If you prefer to set things up yourself:

### 1. Install dependencies

```bash
brew install whisper-cpp

# sox_ng is recommended on macOS 15+ (fixes CoreAudio buffer overrun)
brew install sox_ng
# or: brew install sox
```

### 2. Download the Whisper model

```bash
mkdir -p ~/.local/share/whisper
curl -L -o ~/.local/share/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

This is a ~1.5 GB download. The large-v3-turbo model gives the best accuracy-to-speed ratio on Apple Silicon.

### 3. Install the whisper server LaunchAgent

Edit `com.ptt.whisper-server.plist`:
- Replace `__WHISPER_MODEL_PATH__` with the full path to your model file (e.g., `/Users/you/.local/share/whisper/ggml-large-v3-turbo.bin`)
- Replace `__HOME__` with your home directory path (e.g., `/Users/you`)
- Optionally edit the `--prompt` string to include vocabulary words specific to your domain

Then install:

```bash
mkdir -p ~/.config/ptt
cp com.ptt.whisper-server.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ptt.whisper-server.plist
```

Verify the server is running:

```bash
curl http://127.0.0.1:7178
```

### 4. Install Hammerspoon config

```bash
mkdir -p ~/.hammerspoon
cp init.lua ~/.hammerspoon/init.lua
```

If you already have a Hammerspoon config, append the contents of `init.lua` to your existing file or `require` it as a module.

### 5. Install word fixes

```bash
mkdir -p ~/.config/ptt
cp word-fixes.pl ~/.config/ptt/word-fixes.pl
chmod +x ~/.config/ptt/word-fixes.pl
```

### 6. Grant Hammerspoon Accessibility permissions

System Settings → Privacy & Security → Accessibility → enable Hammerspoon.

This is required for the global hotkey (event tap) and Cmd+V paste simulation to work.

### 7. Launch Hammerspoon

Open Hammerspoon. Enable "Launch Hammerspoon at login" in its preferences. You should see a colored dot appear in your menu bar.

## Configuration

All configuration is at the top of `init.lua`:

| Variable | Default | Description |
|----------|---------|-------------|
| `WHISPER_PORT` | `7178` | Port for the whisper.cpp server |
| `INSERT_KEY_CODE` | `114` | macOS keyCode for the push-to-talk key (114 = Insert/Help) |
| `SILENCE_DURATION` | `"0.4"` | Seconds of silence before a chunk ends |
| `SILENCE_THRESHOLD` | `"1%"` | Audio energy threshold for silence detection |
| `MAX_CHUNK_SECONDS` | `5` | Force-split long speech at this interval |
| `MAX_SESSION_SECONDS` | `120` | Watchdog: force-stop recording after this |
| `MIN_CHUNK_BYTES` | `8000` | Minimum audio size to transcribe (~0.25s) |
| `CLIPBOARD_RESTORE_MS` | `400` | Delay before restoring clipboard after pasting |
| `ENABLE_SOUNDS` | `true` | Enable/disable start/stop audio feedback |

### Changing the hotkey

To use a different key, change `INSERT_KEY_CODE` to the macOS keyCode of your preferred key. To find a key's code, run this in Hammerspoon's console:

```lua
hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e) print(e:getKeyCode()) return false end):start()
```

Press the key you want and check the Hammerspoon console for the keyCode.

### Custom word fixes

Edit `~/.config/ptt/word-fixes.pl` to add project-specific term corrections. Each line is a Perl substitution:

```perl
# Fix a misrecognition
s/\bkubernetes\b/Kubernetes/gi;

# Add a shortcut
s/\bmy email\b/user@example.com/gi;
```

The file is validated on Hammerspoon startup — syntax errors will show an alert.

### Vocabulary hints

The whisper-server `--prompt` parameter accepts a comma-separated list of words that appear frequently in your speech. This biases the model toward recognizing those terms correctly. Edit the prompt in `~/Library/LaunchAgents/com.ptt.whisper-server.plist` and restart:

```bash
launchctl kickstart -k gui/$(id -u)/com.ptt.whisper-server
```

## Voice commands

These are processed by `word-fixes.pl` after transcription:

| Say | Result |
|-----|--------|
| "new line" | Line break |
| "new paragraph" | Double line break |
| "quote" | `"` |
| "open quote" / "close quote" | `"` / `"` (curly quotes) |
| "open paren" / "close paren" | `(` / `)` |
| "open bracket" / "close bracket" | `[` / `]` |
| "open brace" / "close brace" | `{` / `}` |
| "colon" | `:` |
| "semicolon" | `;` |
| "em dash" | `—` |
| "ellipsis" | `…` |
| "tab key" | Tab character |
| "scratch that" | Undo last phrase (Cmd+Z) * |
| "period" (at end of phrase) | `.` |
| "comma" (at end of phrase) | `,` |
| "question mark" (at end of phrase) | `?` |
| "exclamation mark" (at end of phrase) | `!` |

*"Scratch that" is handled directly in `init.lua`, not `word-fixes.pl` — it triggers Cmd+Z rather than a text substitution.

Periods, commas, question marks, and exclamation points are also inserted automatically by Whisper based on speech prosody — you usually don't need to say them.

## Troubleshooting

### Insert key not working

1. Check that Hammerspoon has Accessibility permissions (System Settings → Privacy & Security → Accessibility)
2. Look at the menu bar dot — if it's gray, the whisper server is down
3. Check the debug log: click the menu bar dot → "Show PTT Debug Log"
4. Try reloading: click the menu bar dot → "Reload Hammerspoon"

The event tap watchdog checks every 30 seconds and auto-restarts the hotkey listener if macOS kills it. You'll see a "PTT: Hotkey restored" alert if this happens.

### Whisper server not starting

```bash
# Check if it's running
curl http://127.0.0.1:7178

# Check logs
cat ~/.config/ptt/whisper-server.log
cat ~/.config/ptt/whisper-server-error.log

# Restart manually
launchctl kickstart -k gui/$(id -u)/com.ptt.whisper-server
```

### First syllable getting clipped

This was a known issue with the default SoX silence detection settings and has been fixed. The current settings use a 10ms onset detection window at 0.1% threshold, which captures speech onset almost instantly. If you still experience clipping, try lowering `SILENCE_THRESHOLD` in `init.lua`.

### Text not pasting

The tool uses Cmd+V to paste. Some apps (terminals, VMs) intercept or handle Cmd+V differently. The tool saves and restores your clipboard contents after pasting.

### macOS 15+ (Sequoia) audio issues

If `rec` fails with CoreAudio buffer errors, install `sox_ng` instead of `sox`:

```bash
brew unlink sox
brew install sox_ng
```

## File locations

| File | Purpose |
|------|---------|
| `~/.hammerspoon/init.lua` | Main PTT logic (Hammerspoon config) |
| `~/.config/ptt/word-fixes.pl` | Custom word replacements (Perl) |
| `~/.config/ptt/ptt-debug.log` | Debug log (timestamped) |
| `~/.config/ptt/whisper-server.log` | Whisper server stdout |
| `~/.config/ptt/whisper-server-error.log` | Whisper server stderr |
| `~/Library/LaunchAgents/com.ptt.whisper-server.plist` | LaunchAgent for auto-starting whisper server |
| `~/.local/share/whisper/ggml-large-v3-turbo.bin` | Whisper model file (~1.5 GB) |

## How it stays running

- **Whisper server**: runs as a macOS LaunchAgent with `KeepAlive=true` and `RunAtLoad=true`. Starts at boot, auto-restarts on crash (with 15s throttle to prevent crash loops).
- **Hammerspoon**: set to launch at login. Loads `init.lua` which starts the event tap and watchdog.
- **Event tap watchdog**: polls every 30s to detect if macOS silently killed the hotkey listener. Auto-restarts it.
- **Sleep/wake watcher**: re-checks the event tap 2s after the system wakes from sleep (macOS often kills event taps across sleep cycles).

## License

MIT
