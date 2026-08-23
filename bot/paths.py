"""
paths.py — runtime location helper.

Resolves where config, session state, logs, and the ngrok binary live at
runtime.  The same code runs three ways:

  1. From source           (developer:  `python server.py` in bot/)
  2. From the venv         (LaunchAgent legacy path)
  3. From a py2app bundle  (/Applications/ClaudeCodeRemote.app)

In cases 1-2 the bot/ directory is writable and always exists.  Case 3 is
read-only — code lives inside Contents/Resources/ — so all writable state
goes to ~/Library/Application Support/ClaudeCodeRemote/ and all logs go
to ~/Library/Logs/ClaudeCodeRemote/.

Any legacy bot/config.json or bot/session.json is migrated to the new
location on first access.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

APP_NAME = "ClaudeCodeRemote"


# ── Runtime mode detection ────────────────────────────────────────────────────

def running_in_bundle() -> bool:
    """True when we're running from a py2app-built .app bundle."""
    # py2app sets sys.frozen; also detect the Resources/ layout as a fallback.
    if getattr(sys, "frozen", False):
        return True
    exe = Path(sys.executable).resolve()
    return "Contents/MacOS" in exe.parts or "Contents/Resources" in str(exe)


def bundle_resources_dir() -> Path | None:
    """Return Contents/Resources when running from a bundle, else None."""
    if not running_in_bundle():
        return None
    exe = Path(sys.executable).resolve()
    for parent in exe.parents:
        if parent.name == "Contents":
            return parent / "Resources"
    return None


# ── User-writable locations ───────────────────────────────────────────────────

def config_dir() -> Path:
    """~/Library/Application Support/ClaudeCodeRemote/  (created if missing)."""
    d = Path.home() / "Library" / "Application Support" / APP_NAME
    d.mkdir(parents=True, exist_ok=True)
    return d


def log_dir() -> Path:
    """~/Library/Logs/ClaudeCodeRemote/  (created if missing)."""
    d = Path.home() / "Library" / "Logs" / APP_NAME
    d.mkdir(parents=True, exist_ok=True)
    return d


def config_file() -> Path:
    return config_dir() / "config.json"


def session_file() -> Path:
    return config_dir() / "session.json"


# ── One-time migration from bot/ ──────────────────────────────────────────────

_MIGRATED = False


def migrate_legacy_state() -> None:
    """Copy bot/config.json and bot/session.json into config_dir() if the new
    files don't exist yet.  Idempotent, cheap, safe to call on every import."""
    global _MIGRATED
    if _MIGRATED:
        return
    _MIGRATED = True

    legacy_dir = Path(__file__).parent
    for name in ("config.json", "session.json"):
        legacy = legacy_dir / name
        new = config_dir() / name
        if legacy.exists() and not new.exists():
            try:
                shutil.copy2(legacy, new)
            except OSError:
                pass


# ── claude CLI discovery ──────────────────────────────────────────────────────

# Places the `claude` CLI can end up depending on how it was installed.
# We search these explicitly because a py2app bundle inherits a bare PATH
# (roughly /usr/bin:/bin:/usr/sbin:/sbin) and a LaunchAgent's PATH only
# has what we hardcoded in the plist.
_CLAUDE_SEARCH_DIRS = (
    "~/.local/bin",          # official `claude` installer default
    "/opt/homebrew/bin",     # Apple Silicon Homebrew
    "/usr/local/bin",        # Intel Homebrew / manual installs
    "~/.npm-global/bin",     # user-scoped `npm install -g` prefix
    "~/.volta/bin",          # Volta
    "~/.fnm/aliases/default/bin",  # fnm default
    "~/.nvm/versions/node/*/bin",  # nvm — glob-expanded below
)


def claude_binary() -> str | None:
    """Absolute path to the `claude` CLI, or None if we can't find it.

    Tries PATH first (fast path for developer runs), then a set of
    well-known install locations so we work under a py2app bundle or a
    minimal LaunchAgent PATH.
    """
    on_path = shutil.which("claude")
    if on_path:
        return on_path

    import glob
    home = str(Path.home())
    for pattern in _CLAUDE_SEARCH_DIRS:
        expanded = pattern.replace("~", home)
        for base in glob.glob(expanded):
            candidate = Path(base) / "claude"
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return str(candidate)
    return None


# ── computer-use MCP sidecar discovery ────────────────────────────────────────

def mcp_sidecar() -> str | None:
    """Absolute path to computer_use_mcp.py, or None if it isn't present.

    Must be a *real file on disk* — it is handed to `python3` as a script
    argument. Under py2app the module is compiled into Contents/Resources/
    lib/python314.zip, so `Path(__file__).parent / "computer_use_mcp.py"`
    yields a path inside the zip that no interpreter can open. The bundle
    therefore ships an uncompiled copy alongside it, which this prefers.
    """
    res = bundle_resources_dir()
    if res is not None:
        candidate = res / "computer_use_mcp.py"
        if candidate.is_file():
            return str(candidate)

    # Running from source: it sits next to this module.
    candidate = Path(__file__).resolve().parent / "computer_use_mcp.py"
    return str(candidate) if candidate.is_file() else None


# ── ngrok binary discovery ────────────────────────────────────────────────────

def ngrok_binary() -> str | None:
    """Locate the ngrok binary.  Preference order:

      1. Embedded copy inside the .app bundle (Contents/Resources/bin/ngrok)
      2. Homebrew locations (arm64, then Intel)
      3. Anywhere on PATH
    """
    res = bundle_resources_dir()
    if res is not None:
        candidate = res / "bin" / "ngrok"
        if candidate.exists():
            return str(candidate)

    for hardcoded in ("/opt/homebrew/bin/ngrok", "/usr/local/bin/ngrok"):
        if Path(hardcoded).exists():
            return hardcoded

    on_path = shutil.which("ngrok")
    return on_path
