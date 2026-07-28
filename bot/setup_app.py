"""
setup_app.py — py2app build recipe for ClaudeCodeRemote.app.

Build:
    python setup_app.py py2app

Result:
    ./dist/ClaudeCodeRemote.app   (menu-bar only, no Dock icon)

The bundle contains the FastAPI server, the menu-bar UI, the computer-use
MCP sidecar, and (if found on this machine) a copy of the ngrok binary so
the .app is self-contained.  Config and logs live under
~/Library/Application Support/ClaudeCodeRemote/ and
~/Library/Logs/ClaudeCodeRemote/ — see paths.py.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

from setuptools import setup

BOT_DIR = Path(__file__).parent.resolve()


def _stage_ngrok() -> list[str]:
    """If ngrok is installed, copy it into bin/ngrok inside the source tree
    so py2app picks it up as a Resource (Contents/Resources/bin/ngrok).
    Returns the resources list argument for py2app."""
    for candidate in ("/opt/homebrew/bin/ngrok", "/usr/local/bin/ngrok", shutil.which("ngrok") or ""):
        if candidate and Path(candidate).exists():
            staging = BOT_DIR / "bin"
            staging.mkdir(exist_ok=True)
            dst = staging / "ngrok"
            shutil.copy2(candidate, dst)
            dst.chmod(0o755)
            print(f"[setup_app] bundling ngrok from {candidate}")
            return [str(staging)]
    print("[setup_app] WARNING: ngrok not found on this machine — the .app will fall back to PATH at runtime")
    return []


APP = ["menu_bar.py"]

# Everything menu_bar.py imports (directly or lazily) that py2app might miss.
DATA_FILES: list = []
RESOURCES = _stage_ngrok()

OPTIONS = {
    "argv_emulation": False,
    "packages": [
        "uvicorn",
        "fastapi",
        "starlette",
        "pydantic",
        "rumps",
        "httpx",
        "dotenv",
        "mcp",
        "anyio",
        "sniffio",
        "h11",
        "click",
    ],
    "includes": [
        "server",
        "claude_runner",
        "claude_session",
        "computer_use_mcp",
        "paths",
        "ngrok_supervisor",
    ],
    "resources": RESOURCES,
    "plist": {
        "CFBundleName": "ClaudeCodeRemote",
        "CFBundleDisplayName": "Claude Code Remote",
        "CFBundleIdentifier": "com.claudecoderemote.menubar",
        "CFBundleShortVersionString": "1.0.0",
        "CFBundleVersion": "1",
        "LSUIElement": True,   # menu-bar-only, no Dock icon
        "LSMinimumSystemVersion": "12.0",
        "NSHumanReadableCopyright": "Claude Code Remote",
        "NSHighResolutionCapable": True,
    },
}


if __name__ == "__main__":
    if len(sys.argv) == 1:
        sys.argv.append("py2app")

    setup(
        app=APP,
        name="ClaudeCodeRemote",
        data_files=DATA_FILES,
        options={"py2app": OPTIONS},
        setup_requires=["py2app"],
    )
