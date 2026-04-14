#!/usr/bin/env python3
"""
computer_use_mcp.py
Minimal MCP server that gives Claude Code computer-use capabilities on macOS:
  - screenshot  — capture the screen and return it as an image
  - left_click  — click the mouse at (x, y)
  - double_click — double-click at (x, y)
  - right_click — right-click at (x, y)
  - mouse_move  — move the cursor to (x, y) without clicking
  - type        — type a string of text
  - key         — press a named key or chord (e.g. "return", "cmd+c")
  - scroll      — scroll the mouse wheel at (x, y)

Dependencies (installed by setup.sh):
  brew install cliclick          — mouse control
  pip install mcp               — MCP stdio server framework
"""

import asyncio
import base64
import subprocess
import tempfile
import os
import sys
from pathlib import Path

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp import types

# ---------------------------------------------------------------------------
# Key name → AppleScript key code mapping
# ---------------------------------------------------------------------------
_KEY_CODES: dict[str, int] = {
    "return": 36,
    "enter": 36,
    "tab": 48,
    "space": 49,
    "delete": 51,      # Backspace
    "backspace": 51,
    "forward_delete": 117,
    "escape": 53,
    "esc": 53,
    "up": 126,
    "down": 125,
    "left": 123,
    "right": 124,
    "f1": 122, "f2": 120, "f3": 99,  "f4": 118,
    "f5": 96,  "f6": 97,  "f7": 98,  "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "home": 115, "end": 119, "page_up": 116, "page_down": 121,
}

_MOD_MAP = {
    "cmd": "command down",
    "command": "command down",
    "ctrl": "control down",
    "control": "control down",
    "opt": "option down",
    "option": "option down",
    "alt": "option down",
    "shift": "shift down",
}


def _run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kwargs)


# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

def do_screenshot() -> list[types.TextContent | types.ImageContent]:
    """Capture the screen and return a base64-encoded PNG."""
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        tmpfile = f.name
    try:
        _run(["screencapture", "-x", tmpfile])
        data = base64.b64encode(Path(tmpfile).read_bytes()).decode()
        return [types.ImageContent(type="image", data=data, mimeType="image/png")]
    finally:
        try:
            os.unlink(tmpfile)
        except FileNotFoundError:
            pass


def _cliclick(*args: str) -> str:
    result = _run(["cliclick"] + list(args))
    return result.stdout.strip() or "ok"


def do_left_click(x: int, y: int) -> list[types.TextContent]:
    _cliclick(f"c:{x},{y}")
    return [types.TextContent(type="text", text=f"Left-clicked at ({x}, {y})")]


def do_double_click(x: int, y: int) -> list[types.TextContent]:
    _cliclick(f"dc:{x},{y}")
    return [types.TextContent(type="text", text=f"Double-clicked at ({x}, {y})")]


def do_right_click(x: int, y: int) -> list[types.TextContent]:
    _cliclick(f"rc:{x},{y}")
    return [types.TextContent(type="text", text=f"Right-clicked at ({x}, {y})")]


def do_mouse_move(x: int, y: int) -> list[types.TextContent]:
    _cliclick(f"m:{x},{y}")
    return [types.TextContent(type="text", text=f"Moved mouse to ({x}, {y})")]


def do_scroll(x: int, y: int, direction: str, amount: int) -> list[types.TextContent]:
    # cliclick scroll: su = scroll up, sd = scroll down
    dir_map = {"up": "su", "down": "sd", "left": "sl", "right": "sr"}
    code = dir_map.get(direction.lower(), "sd")
    _cliclick(f"m:{x},{y}", f"{code}:{amount}")
    return [types.TextContent(type="text", text=f"Scrolled {direction} {amount} at ({x}, {y})")]


def do_type(text: str) -> list[types.TextContent]:
    """Type a string. Uses cliclick for best compatibility."""
    # cliclick t: handles most text; for special chars fallback to AppleScript
    try:
        _cliclick(f"t:{text}")
    except subprocess.CalledProcessError:
        # Fallback: AppleScript keystroke
        escaped = text.replace("\\", "\\\\").replace('"', '\\"')
        _run(["osascript", "-e", f'tell application "System Events" to keystroke "{escaped}"'])
    return [types.TextContent(type="text", text=f"Typed: {repr(text)}")]


def do_key(key: str) -> list[types.TextContent]:
    """Press a key or chord like 'return', 'cmd+c', 'shift+tab'."""
    parts = key.lower().split("+")
    base = parts[-1]
    mods = [_MOD_MAP[m] for m in parts[:-1] if m in _MOD_MAP]

    if base in _KEY_CODES:
        code = _KEY_CODES[base]
        if mods:
            using = "{" + ", ".join(mods) + "}"
            script = f'tell application "System Events" to key code {code} using {using}'
        else:
            script = f'tell application "System Events" to key code {code}'
    else:
        # Printable character — use keystroke
        if mods:
            using = "{" + ", ".join(mods) + "}"
            script = f'tell application "System Events" to keystroke "{base}" using {using}'
        else:
            script = f'tell application "System Events" to keystroke "{base}"'

    _run(["osascript", "-e", script])
    return [types.TextContent(type="text", text=f"Pressed key: {key}")]


# ---------------------------------------------------------------------------
# MCP server setup
# ---------------------------------------------------------------------------

server = Server("computer-use")


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="screenshot",
            description=(
                "Take a screenshot of the entire screen. "
                "Returns the image so you can see what's on screen before clicking."
            ),
            inputSchema={"type": "object", "properties": {}, "required": []},
        ),
        types.Tool(
            name="left_click",
            description="Click the left mouse button at pixel coordinates (x, y).",
            inputSchema={
                "type": "object",
                "properties": {
                    "x": {"type": "integer", "description": "X pixel coordinate"},
                    "y": {"type": "integer", "description": "Y pixel coordinate"},
                },
                "required": ["x", "y"],
            },
        ),
        types.Tool(
            name="double_click",
            description="Double-click at pixel coordinates (x, y).",
            inputSchema={
                "type": "object",
                "properties": {
                    "x": {"type": "integer", "description": "X pixel coordinate"},
                    "y": {"type": "integer", "description": "Y pixel coordinate"},
                },
                "required": ["x", "y"],
            },
        ),
        types.Tool(
            name="right_click",
            description="Right-click at pixel coordinates (x, y) to open context menus.",
            inputSchema={
                "type": "object",
                "properties": {
                    "x": {"type": "integer", "description": "X pixel coordinate"},
                    "y": {"type": "integer", "description": "Y pixel coordinate"},
                },
                "required": ["x", "y"],
            },
        ),
        types.Tool(
            name="mouse_move",
            description="Move the mouse cursor to (x, y) without clicking.",
            inputSchema={
                "type": "object",
                "properties": {
                    "x": {"type": "integer", "description": "X pixel coordinate"},
                    "y": {"type": "integer", "description": "Y pixel coordinate"},
                },
                "required": ["x", "y"],
            },
        ),
        types.Tool(
            name="type",
            description="Type a string of text as keyboard input into the focused application.",
            inputSchema={
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Text to type"},
                },
                "required": ["text"],
            },
        ),
        types.Tool(
            name="key",
            description=(
                "Press a named key or keyboard shortcut. "
                "Examples: 'return', 'escape', 'tab', 'space', 'delete', "
                "'up', 'down', 'left', 'right', 'cmd+c', 'cmd+v', 'shift+tab', "
                "'cmd+shift+3' (screenshot), 'cmd+space' (Spotlight)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "key": {
                        "type": "string",
                        "description": "Key name or chord (e.g. 'return', 'cmd+c')",
                    },
                },
                "required": ["key"],
            },
        ),
        types.Tool(
            name="scroll",
            description="Scroll the mouse wheel at (x, y).",
            inputSchema={
                "type": "object",
                "properties": {
                    "x": {"type": "integer", "description": "X pixel coordinate"},
                    "y": {"type": "integer", "description": "Y pixel coordinate"},
                    "direction": {
                        "type": "string",
                        "enum": ["up", "down", "left", "right"],
                        "description": "Scroll direction",
                    },
                    "amount": {
                        "type": "integer",
                        "description": "Number of scroll steps (default 3)",
                        "default": 3,
                    },
                },
                "required": ["x", "y", "direction"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(
    name: str, arguments: dict
) -> list[types.TextContent | types.ImageContent | types.EmbeddedResource]:
    try:
        if name == "screenshot":
            return do_screenshot()
        elif name == "left_click":
            return do_left_click(int(arguments["x"]), int(arguments["y"]))
        elif name == "double_click":
            return do_double_click(int(arguments["x"]), int(arguments["y"]))
        elif name == "right_click":
            return do_right_click(int(arguments["x"]), int(arguments["y"]))
        elif name == "mouse_move":
            return do_mouse_move(int(arguments["x"]), int(arguments["y"]))
        elif name == "type":
            return do_type(str(arguments["text"]))
        elif name == "key":
            return do_key(str(arguments["key"]))
        elif name == "scroll":
            return do_scroll(
                int(arguments["x"]),
                int(arguments["y"]),
                str(arguments.get("direction", "down")),
                int(arguments.get("amount", 3)),
            )
        else:
            return [types.TextContent(type="text", text=f"Unknown tool: {name}")]
    except subprocess.CalledProcessError as e:
        err = e.stderr.strip() if e.stderr else str(e)
        return [types.TextContent(type="text", text=f"Error running {name}: {err}")]
    except Exception as e:
        return [types.TextContent(type="text", text=f"Error in {name}: {e}")]


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
