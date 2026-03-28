#!/bin/bash
set -euo pipefail

# whisper-ptt installer
# Sets up: whisper.cpp server, Hammerspoon config, word fixes, LaunchAgent

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$HOME/.local/share/whisper"
MODEL_FILE="$MODEL_DIR/ggml-large-v3-turbo.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
PTT_CONFIG_DIR="$HOME/.config/ptt"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_LABEL="com.ptt.whisper-server"

echo ""
echo "  whisper-ptt installer"
echo "  ====================="
echo ""

# -----------------------------------------------------------------------
# Check prerequisites
# -----------------------------------------------------------------------

info "Checking prerequisites..."

if [[ "$(uname)" != "Darwin" ]]; then
    error "This tool only runs on macOS."
fi

if ! command -v brew &>/dev/null; then
    error "Homebrew is required. Install from https://brew.sh"
fi

# -----------------------------------------------------------------------
# Install whisper.cpp (whisper-server)
# -----------------------------------------------------------------------

if ! command -v whisper-server &>/dev/null; then
    info "Installing whisper.cpp..."
    brew install whisper-cpp
else
    info "whisper.cpp already installed: $(which whisper-server)"
fi

# -----------------------------------------------------------------------
# Install sox (for recording)
# -----------------------------------------------------------------------

if ! command -v rec &>/dev/null; then
    info "Installing sox..."
    # sox_ng fixes CoreAudio buffer overrun on macOS 15+
    if brew info sox_ng &>/dev/null 2>&1; then
        brew install sox_ng
    else
        brew install sox
    fi
else
    info "sox already installed: $(which rec)"
fi

# -----------------------------------------------------------------------
# Check Hammerspoon
# -----------------------------------------------------------------------

if [ ! -d "/Applications/Hammerspoon.app" ] && [ ! -d "$HOME/Applications/Hammerspoon.app" ]; then
    warn "Hammerspoon not found. Install from https://www.hammerspoon.org/"
    warn "After installing, grant it Accessibility permissions in:"
    warn "  System Settings → Privacy & Security → Accessibility"
    echo ""
    read -p "Press Enter once Hammerspoon is installed, or Ctrl+C to quit..."
fi

# -----------------------------------------------------------------------
# Download Whisper model
# -----------------------------------------------------------------------

if [ ! -f "$MODEL_FILE" ]; then
    info "Downloading Whisper large-v3-turbo model (~1.5 GB)..."
    mkdir -p "$MODEL_DIR"
    curl -L --progress-bar -o "$MODEL_FILE" "$MODEL_URL"
    info "Model downloaded to $MODEL_FILE"
else
    info "Whisper model already exists: $MODEL_FILE"
fi

# -----------------------------------------------------------------------
# Create config directory
# -----------------------------------------------------------------------

mkdir -p "$PTT_CONFIG_DIR"

# -----------------------------------------------------------------------
# Install word-fixes.pl
# -----------------------------------------------------------------------

if [ ! -f "$PTT_CONFIG_DIR/word-fixes.pl" ]; then
    info "Installing word-fixes.pl → $PTT_CONFIG_DIR/"
    cp "$SCRIPT_DIR/word-fixes.pl" "$PTT_CONFIG_DIR/word-fixes.pl"
    chmod +x "$PTT_CONFIG_DIR/word-fixes.pl"
else
    warn "word-fixes.pl already exists — skipping (edit at $PTT_CONFIG_DIR/word-fixes.pl)"
fi

# -----------------------------------------------------------------------
# Install Hammerspoon init.lua
# -----------------------------------------------------------------------

HS_DIR="$HOME/.hammerspoon"
mkdir -p "$HS_DIR"

if [ -f "$HS_DIR/init.lua" ]; then
    warn "Existing $HS_DIR/init.lua found."
    echo ""
    echo "  Options:"
    echo "    1) Replace it (backup saved as init.lua.bak)"
    echo "    2) Append PTT code to existing init.lua"
    echo "    3) Skip — I'll install it manually"
    echo ""
    read -p "  Choice [1/2/3]: " choice
    case "$choice" in
        1)
            cp "$HS_DIR/init.lua" "$HS_DIR/init.lua.bak"
            info "Backed up existing init.lua → init.lua.bak"
            cp "$SCRIPT_DIR/init.lua" "$HS_DIR/init.lua"
            info "Installed init.lua"
            ;;
        2)
            echo "" >> "$HS_DIR/init.lua"
            echo "-- ========== whisper-ptt (appended by installer) ==========" >> "$HS_DIR/init.lua"
            cat "$SCRIPT_DIR/init.lua" >> "$HS_DIR/init.lua"
            info "Appended PTT code to existing init.lua"
            ;;
        3)
            warn "Skipped. Copy init.lua manually:"
            warn "  cp $SCRIPT_DIR/init.lua $HS_DIR/init.lua"
            ;;
        *)
            warn "Invalid choice — skipping init.lua installation"
            ;;
    esac
else
    cp "$SCRIPT_DIR/init.lua" "$HS_DIR/init.lua"
    info "Installed init.lua → $HS_DIR/"
fi

# -----------------------------------------------------------------------
# Install LaunchAgent for whisper-server
# -----------------------------------------------------------------------

info "Installing whisper-server LaunchAgent..."
mkdir -p "$LAUNCH_AGENT_DIR"

sed \
    -e "s|__WHISPER_MODEL_PATH__|$MODEL_FILE|g" \
    -e "s|__HOME__|$HOME|g" \
    "$SCRIPT_DIR/com.ptt.whisper-server.plist" \
    > "$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_LABEL.plist"

info "LaunchAgent installed → $LAUNCH_AGENT_DIR/$LAUNCH_AGENT_LABEL.plist"

# -----------------------------------------------------------------------
# Start whisper-server
# -----------------------------------------------------------------------

info "Loading whisper-server LaunchAgent..."
launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_LABEL.plist"
info "Whisper server starting on http://127.0.0.1:7178"

# -----------------------------------------------------------------------
# Reload Hammerspoon
# -----------------------------------------------------------------------

if pgrep -q Hammerspoon; then
    info "Reloading Hammerspoon..."
    hs -c 'hs.reload()' 2>/dev/null || warn "Could not reload Hammerspoon automatically — please reload manually (click menu bar icon → Reload Config)"
fi

# -----------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------

echo ""
info "Installation complete!"
echo ""
echo "  Usage:"
echo "    Hold Insert key → speak → release → text is pasted"
echo "    Press Escape while recording → cancel"
echo "    Say 'scratch that' → undo last phrase"
echo ""
echo "  Menu bar: look for the colored dot indicator"
echo "    Green  = ready"
echo "    Red    = recording"
echo "    Orange = transcribing"
echo "    Gray   = whisper server offline"
echo ""
echo "  Config files:"
echo "    $HS_DIR/init.lua              — main PTT logic"
echo "    $PTT_CONFIG_DIR/word-fixes.pl — custom word replacements"
echo "    $PTT_CONFIG_DIR/ptt-debug.log — debug log"
echo ""

if [ ! -d "/Applications/Hammerspoon.app" ] && [ ! -d "$HOME/Applications/Hammerspoon.app" ]; then
    warn "Don't forget to install Hammerspoon and grant Accessibility permissions!"
fi
