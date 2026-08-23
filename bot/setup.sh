#!/usr/bin/env bash
# setup.sh — one-time setup for the Claude Code Remote bot server.
# Builds ClaudeCodeRemote.app, installs it to /Applications, and registers
# a LaunchAgent so it starts at every login.
#
# Run this from the bot/ directory: bash setup.sh

set -euo pipefail

echo "=== Claude Code Remote — Bot Server Setup ==="
echo ""

# ── 1. Python environment ────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found. Install Python 3.11+ first."
    exit 1
fi

echo "Creating Python virtual environment..."
python3 -m venv .venv
source .venv/bin/activate

echo "Installing dependencies (includes py2app)..."
pip install -q --upgrade pip
pip install -q -r requirements.txt

# ── 2. cliclick (mouse/keyboard automation) ──────────────────────────────────
if ! command -v cliclick &>/dev/null; then
    echo ""
    echo "Installing cliclick (mouse & keyboard automation for computer-use)..."
    if command -v brew &>/dev/null; then
        brew install cliclick
    else
        echo "WARNING: Homebrew not found — skipping cliclick. Mouse/keyboard computer-use tools will not work."
    fi
fi

# ── 3. Claude Code CLI ───────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
    echo ""
    echo "Claude Code CLI not found. Installing..."
    if command -v npm &>/dev/null; then
        npm install -g @anthropic-ai/claude-code
    else
        echo "ERROR: npm not found. Install Node.js first: https://nodejs.org"
        exit 1
    fi
fi
echo "Claude Code CLI: $(claude --version 2>/dev/null || echo 'installed')"

# ── 4. .env file ─────────────────────────────────────────────────────────────
if [ ! -f .env ] && [ -f .env.example ]; then
    cp .env.example .env
    echo ""
    echo "Created .env from .env.example."
fi

# ── 5. ngrok ─────────────────────────────────────────────────────────────────
echo ""
if command -v ngrok &>/dev/null; then
    echo "ngrok found: $(ngrok version)"
else
    echo "ngrok not found. Installing via Homebrew..."
    if command -v brew &>/dev/null; then
        brew install ngrok/ngrok/ngrok
        echo "ngrok installed: $(ngrok version)"
    else
        echo "ERROR: Homebrew not found. Install ngrok manually: https://ngrok.com/download"
        exit 1
    fi
fi
echo ""
echo ">>> If you haven't authenticated ngrok yet, either:"
echo "      • run  ngrok config add-authtoken <your-token>"
echo "      • or click 'Configure ngrok…' from the ☁ menu bar after launch"
echo "    Get your token at https://dashboard.ngrok.com/get-started/your-authtoken"
echo ">>> For a stable magic link, claim your free static domain at"
echo "      https://dashboard.ngrok.com  →  Domains"
echo "    and paste it into 'Configure ngrok…'."

# ── 6. Login to Claude ───────────────────────────────────────────────────────
echo ""
echo "If you haven't already, log in to Claude Code:  claude login"
echo ""

# ── 7. Build ClaudeCodeRemote.app with py2app ────────────────────────────────
echo "Building ClaudeCodeRemote.app…"
rm -rf build dist
python setup_app.py py2app

BUILT_APP="dist/ClaudeCodeRemote.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "ERROR: py2app did not produce $BUILT_APP"
    exit 1
fi

# ── 8. Install into /Applications ────────────────────────────────────────────
INSTALLED_APP="/Applications/ClaudeCodeRemote.app"
echo "Installing to ${INSTALLED_APP}…"
# Stop any running instance so we can replace the bundle.
osascript -e 'tell application "ClaudeCodeRemote" to quit' 2>/dev/null || true
rm -rf "$INSTALLED_APP"
cp -R "$BUILT_APP" "$INSTALLED_APP"

# ── 9. LaunchAgent that points at the installed .app ─────────────────────────
PLIST_LABEL="com.claudecoderemote.menubar"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$PLIST_LABEL.plist"
APP_BINARY="$INSTALLED_APP/Contents/MacOS/ClaudeCodeRemote"
LOG_DIR_HOME="$HOME/Library/Logs/ClaudeCodeRemote"
mkdir -p "$PLIST_DIR" "$LOG_DIR_HOME"

launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true

cat > "$PLIST_PATH" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_BINARY</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR_HOME/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR_HOME/launchd.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST_EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
echo "LaunchAgent loaded. Look for ☁ in your menu bar (may take a few seconds)."

# ── 10. Done ────────────────────────────────────────────────────────────────
echo ""
echo "=== Setup complete! ==="
echo ""
echo "IMPORTANT — macOS permissions needed for computer-use (screenshot/click/type):"
echo "  System Settings → Privacy & Security → Screen Recording → enable ClaudeCodeRemote"
echo "  System Settings → Privacy & Security → Accessibility     → enable ClaudeCodeRemote"
echo ""
echo "The menu bar app auto-starts at every login."
echo ""
echo "To share with your friend:"
echo "  1. Click the ☁ (or ☁✓) icon in your menu bar"
echo "  2. Click 'Copy Magic Link'"
echo "  3. Paste it into iMessage / WhatsApp"
echo ""
echo "Config & state:  ~/Library/Application Support/ClaudeCodeRemote/"
echo "Logs:            ~/Library/Logs/ClaudeCodeRemote/"
echo "To stop:         launchctl bootout gui/\$(id -u)/com.claudecoderemote.menubar"
echo "To restart:      launchctl kickstart gui/\$(id -u)/com.claudecoderemote.menubar"
echo ""
