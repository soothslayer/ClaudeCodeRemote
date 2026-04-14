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

# ── 2. Claude Code CLI ───────────────────────────────────────────────────────
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

# ── 3. .env file ─────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    cp .env.example .env
    echo ""
    echo "Created .env from .env.example."
    echo ">>> Open bot/.env and add your TELEGRAM_BOT_TOKEN (optional but recommended)."
fi

# ── 4. ngrok ────────────────────────────────────────────────────────────────
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

# ── 5. Login to Claude ───────────────────────────────────────────────────────
echo ""
echo "If you haven't already, log in to Claude Code:"
echo "  claude login"
echo ""

# ── 6. Start server ──────────────────────────────────────────────────────────
echo "=== Setup complete! ==="
echo ""
echo "To start the server:"
echo "  1. In one terminal:   source .venv/bin/activate && python server.py"
echo "  2. In another:        ngrok http 8080"
echo "  3. Copy the ngrok https:// URL into the iOS app (long press the main screen → Settings)"
echo ""
echo "To receive Telegram push notifications:"
echo "  1. Create a Telegram bot via @BotFather and add the token to bot/.env"
echo "  2. Send /start to your new bot on Telegram — it will register your chat ID automatically"
echo ""
