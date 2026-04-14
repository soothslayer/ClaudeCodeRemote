"""
claude_runner.py
Runs the Claude Code CLI as a subprocess and returns the final text response.

Requires the `claude` CLI to be installed and authenticated:
    npm install -g @anthropic-ai/claude-code
    claude login
"""

import subprocess
import json
import uuid
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

# Directory Claude Code will run in (i.e. the project it works on)
WORK_DIR = Path("~/git/buck").expanduser()


def run_claude(prompt: str, session_id: str | None = None) -> tuple[str, str]:
    """
    Run Claude Code non-interactively.

    Returns:
        (response_text, session_id)  — session_id may be new or the same one passed in.

    Raises:
        RuntimeError if Claude Code exits with an error.
    """
    cmd = [
        "claude",
        "--print", prompt,
        "--output-format", "json",
        "--dangerously-skip-permissions",
    ]
    if session_id:
        cmd += ["--resume", session_id]

    logger.info("Running claude: session=%s prompt_len=%d", session_id, len(prompt))

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300,          # 5-minute hard cap
            cwd=str(WORK_DIR),
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("Claude Code timed out after 5 minutes.")

    if result.returncode != 0:
        stderr = result.stderr.strip()
        raise RuntimeError(f"Claude Code exited {result.returncode}: {stderr or 'no error output'}")

    return _parse_output(result.stdout, session_id)


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
