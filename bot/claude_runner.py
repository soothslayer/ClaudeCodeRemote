"""
claude_runner.py
Runs the Claude Code CLI as a subprocess and returns the final text response.

Requires the `claude` CLI to be installed and authenticated:
    npm install -g @anthropic-ai/claude-code
    claude login
"""

import os
import signal
import subprocess
import json
import uuid
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

# Directory Claude Code will run in (i.e. the project it works on).
# Set CLAUDE_WORK_DIR in your environment or .env to override.
import os as _os
_work_dir_env = _os.environ.get("CLAUDE_WORK_DIR", "")
WORK_DIR = Path(_work_dir_env).expanduser() if _work_dir_env else Path.home()
if not WORK_DIR.exists():
    logger.warning("WORK_DIR %s does not exist — falling back to home directory", WORK_DIR)
    WORK_DIR = Path.home()

# Path to our computer-use MCP server script
_MCP_SERVER = Path(__file__).parent / "computer_use_mcp.py"

# Inline --mcp-config JSON: starts our local computer-use MCP server as a sidecar
_MCP_CONFIG = json.dumps({
    "mcpServers": {
        "mac-input": {
            "type": "stdio",
            "command": "python3",
            "args": [str(_MCP_SERVER)],
        }
    }
})


def start_claude(prompt: str, session_id: str | None = None) -> subprocess.Popen:
    """
    Launch Claude Code as a non-blocking subprocess.

    The caller is responsible for waiting on the process (via collect_claude)
    or killing it (via kill_claude) when the client disconnects.

    start_new_session=True gives the child its own process group so that
    kill_claude can SIGTERM the whole tree (claude + MCP server sidecar)
    without affecting this server process.
    """
    cmd = [
        "claude",
        "--print", prompt,
        "--output-format", "json",
        "--dangerously-skip-permissions",
        "--mcp-config", _MCP_CONFIG,
    ]
    if session_id:
        cmd += ["--resume", session_id]

    logger.info("Starting claude: session=%s prompt_len=%d", session_id, len(prompt))
    return subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=str(WORK_DIR),
        start_new_session=True,   # own process group → safe to kill tree
    )


def collect_claude(proc: subprocess.Popen, session_id: str | None) -> tuple[str, str]:
    """
    Block until the Claude subprocess finishes and return (response, session_id).
    Call this from a thread (asyncio.to_thread / run_in_executor).

    Raises RuntimeError on non-zero exit.
    """
    stdout, stderr = proc.communicate()   # no timeout — let Claude run as long as needed

    if proc.returncode != 0:
        err = stderr.strip()
        raise RuntimeError(f"Claude Code exited {proc.returncode}: {err or 'no error output'}")

    return _parse_output(stdout, session_id)


def kill_claude(proc: subprocess.Popen) -> None:
    """
    Kill the Claude subprocess tree (claude binary + MCP server sidecar).
    Safe to call even if the process has already exited.
    """
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        logger.info("Sent SIGTERM to claude process group (pid=%d)", proc.pid)
    except (ProcessLookupError, PermissionError):
        pass   # already dead
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            pass


# Kept for any callers that don't need cancellation support.
def run_claude(prompt: str, session_id: str | None = None) -> tuple[str, str]:
    proc = start_claude(prompt, session_id)
    return collect_claude(proc, session_id)


def _parse_output(raw: str, fallback_session_id: str | None) -> tuple[str, str]:
    """
    Claude Code --output-format json streams newline-delimited JSON objects.
    The final object with "type": "result" carries the assistant's text.
    """
    final_result: str | None = None
    returned_session_id: str | None = None

    for line in raw.strip().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue

        if obj.get("type") == "result":
            final_result = obj.get("result", "")
            returned_session_id = obj.get("session_id") or fallback_session_id
            # Keep iterating — take the last result object
        elif obj.get("type") == "error":
            raise RuntimeError(obj.get("error", "Unknown error from Claude Code"))

    if final_result is None:
        # Fallback: treat entire stdout as plain text
        final_result = raw.strip() or "No response from Claude Code."

    if not returned_session_id:
        returned_session_id = fallback_session_id or str(uuid.uuid4())

    logger.info("Claude response: session=%s len=%d", returned_session_id, len(final_result))
    return final_result, returned_session_id
