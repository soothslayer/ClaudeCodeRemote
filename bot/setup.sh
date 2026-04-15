#!/usr/bin/env bash
# setup.sh — one-time setup for the Claude Code Remote bot server
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

echo "Installing dependencies..."
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

# ── 4. Claude Code CLI ───────────────────────────────────────────────────────
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

# ── 5. .env file ─────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    cp .env.example .env
    echo ""
    echo "Created .env from .env.example."
    echo ">>> Open bot/.env and add your TELEGRAM_BOT_TOKEN (optional but recommended)."
fi

# ── 6. ngrok ────────────────────────────────────────────────────────────────
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
echo ">>> If you haven't authenticated ngrok yet, run:"
echo "      ngrok config add-authtoken <your-token>"
echo "    Get your token at: https://dashboard.ngrok.com/get-started/your-authtoken"

# ── 7. Login to Claude ───────────────────────────────────────────────────────
echo ""
echo "If you haven't already, log in to Claude Code:"
echo "  claude login"
echo ""

# ── 8. Menu bar app — install as a login item via LaunchAgent ────────────────
echo ""
echo "Installing Claude Code Remote as a login-startup menu bar app…"

PLIST_LABEL="com.claudecoderemote.menubar"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$PLIST_LABEL.plist"
LOG_DIR="$HOME/Library/Logs"
VENV_PYTHON="$(pwd)/.venv/bin/python3"
MENU_BAR_PY="$(pwd)/menu_bar.py"

mkdir -p "$PLIST_DIR" "$LOG_DIR"

# Unload any previous version (idempotent)
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
    <string>$VENV_PYTHON</string>
    <string>$MENU_BAR_PY</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/claude_remote.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/claude_remote_err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST_EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
echo "Menu bar app loaded. Look for ☁ in your menu bar (may take a few seconds)."

# ── 9. Done ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Setup complete! ==="
echo ""
echo "IMPORTANT — macOS permissions needed for computer-use (screenshot/click/type):"
echo "  Open System Settings → Privacy & Security → Screen Recording"
echo "  → Enable the menu bar app's Python process (or Terminal if prompted)"
echo "  Open System Settings → Privacy & Security → Accessibility"
echo "  → Enable the same Python process (needed for keyboard/mouse automation)"
echo ""
echo "The Claude Code Remote server and ngrok start automatically at every login."
echo ""
echo "To share with your friend:"
echo "  1. Click the ☁ (or ☁✓) icon in your menu bar"
echo "  2. Click 'Copy Magic Link'"
echo "  3. Paste it into iMessage / WhatsApp and send it to them"
echo "  4. They tap the link on their iPhone — the app connects automatically"
echo ""
echo "To view logs:   tail -f ~/Library/Logs/claude_remote.log"
echo "To stop:        launchctl bootout gui/\$(id -u)/com.claudecoderemote.menubar"
echo "To restart:     launchctl kickstart gui/\$(id -u)/com.claudecoderemote.menubar"
echo ""
echo "To receive Telegram push notifications:"
echo "  1. Create a Telegram bot via @BotFather and add the token to bot/.env"
echo "  2. Send /start to your new bot on Telegram — it will register your chat ID automatically"
echo ""
