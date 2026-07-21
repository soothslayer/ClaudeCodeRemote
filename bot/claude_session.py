"""
claude_session.py
Persistent Claude Code process for full-duplex conversations.

Instead of spawning `claude --print <prompt>` per turn (claude_runner.py),
this module keeps ONE long-lived Claude process alive across turns:

    claude --print --input-format stream-json --output-format stream-json \
           --include-partial-messages --verbose [--resume <id>]

User messages are written to stdin as stream-json while the process runs —
mid-run messages steer the current turn.  An interrupt control_request
aborts the current turn without killing the process.  Stdout is parsed on a
reader thread and normalized into speakable events for the WebSocket layer.
"""

import json
import logging
import os
import signal
import subprocess
import threading
import uuid
from collections.abc import Callable
from pathlib import Path

logger = logging.getLogger(__name__)

# Same computer-use MCP sidecar claude_runner.py uses.
_MCP_SERVER = Path(__file__).parent / "computer_use_mcp.py"
_MCP_CONFIG = json.dumps({
    "mcpServers": {
        "mac-input": {
            "type": "stdio",
            "command": "python3",
            "args": [str(_MCP_SERVER)],
        }
    }
})


def _tool_summary(name: str, tool_input: dict | None) -> str:
    """Short, speakable description of a tool call."""
    tool_input = tool_input or {}
    if name == "Bash":
        cmd = str(tool_input.get("command", "")).split("\n")[0]
        return f"Running command: {cmd[:60]}" if cmd else "Running a command"
    if name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        path = str(tool_input.get("file_path", ""))
        return f"Editing {os.path.basename(path)}" if path else "Editing a file"
    if name == "Read":
        path = str(tool_input.get("file_path", ""))
        return f"Reading {os.path.basename(path)}" if path else "Reading a file"
    if name in ("Glob", "Grep"):
        return "Searching the code"
    if name in ("WebSearch", "WebFetch"):
        return "Searching the web"
    if name in ("Task", "Agent"):
        return "Delegating to a sub agent"
    return f"Using {name}"


class ClaudeSession:
    """
    One persistent Claude Code subprocess.

    on_event(evt) receives normalized dicts (called from the reader thread):
        {"type": "session", "session_id": str}
        {"type": "assistant_delta", "text": str}
        {"type": "tool_activity", "text": str}
        {"type": "turn_done", "text": str, "session_id": str}
        {"type": "status", "state": "working" | "idle"}
        {"type": "error", "message": str}

    on_raw(line) receives every raw stdout JSON line (for the /activity page).
    """

    def __init__(
        self,
        on_event: Callable[[dict], None],
        on_raw: "Callable[[str], None] | None" = None,
    ):
        self._on_event = on_event
        self._on_raw = on_raw
        self._proc: subprocess.Popen | None = None
        self._stdin_lock = threading.Lock()
        self._reader: threading.Thread | None = None
        self.session_id: str | None = None
        self._work_dir: Path = Path.home()
        self._got_init = False
        self._resume_attempted: str | None = None

    # ── Lifecycle ────────────────────────────────────────────────────────────

    @property
    def is_running(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def start(self, session_id: str | None, work_dir: "str | Path | None" = None) -> None:
        """Spawn the persistent process. Kills any existing one first."""
        self.close()

        if work_dir:
            cwd = Path(work_dir).expanduser()
            if cwd.exists():
                self._work_dir = cwd
            else:
                logger.warning("work_dir %s does not exist — using home", cwd)
                self._work_dir = Path.home()

        cmd = [
            "claude",
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--dangerously-skip-permissions",
            "--mcp-config", _MCP_CONFIG,
        ]
        if session_id:
            cmd += ["--resume", session_id]

        self.session_id = session_id
        self._got_init = False
        self._resume_attempted = session_id

        logger.info("Starting persistent claude: resume=%s work_dir=%s", session_id, self._work_dir)
        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,                # line-buffered
            cwd=str(self._work_dir),
            start_new_session=True,   # own process group → safe to kill tree
        )
        self._reader = threading.Thread(
            target=self._read_loop, args=(self._proc,), daemon=True,
        )
        self._reader.start()
        threading.Thread(
            target=self._drain_stderr, args=(self._proc,), daemon=True,
        ).start()

    def close(self) -> None:
        """Kill the process tree (claude + MCP sidecar). Safe if already dead."""
        proc = self._proc
        self._proc = None
        if proc is None or proc.poll() is not None:
            return
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            return
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except Exception:
                pass

    # ── Input ────────────────────────────────────────────────────────────────

    def send_user(self, text: str) -> None:
        """
        Send a user message.  If Claude is mid-turn this steers the current
        run; if idle it starts a new turn.  Restarts a dead process first.
        """
        if not self.is_running:
            logger.info("Claude process not running — restarting (resume=%s)", self.session_id)
            self.start(self.session_id, self._work_dir)
        msg = {
            "type": "user",
            "message": {"role": "user", "content": [{"type": "text", "text": text}]},
        }
        self._write_line(json.dumps(msg))
        self._on_event({"type": "status", "state": "working"})

    def interrupt(self) -> None:
        """Abort the current turn (process stays alive for the next one)."""
        if not self.is_running:
            return
        req = {
            "type": "control_request",
            "request_id": f"req_{uuid.uuid4().hex[:12]}",
            "request": {"subtype": "interrupt"},
        }
        self._write_line(json.dumps(req))
        logger.info("Sent interrupt control_request")

    def _write_line(self, line: str) -> None:
        proc = self._proc
        if proc is None or proc.stdin is None:
            raise RuntimeError("Claude process is not running")
        with self._stdin_lock:
            proc.stdin.write(line + "\n")
            proc.stdin.flush()

    # ── Output parsing ───────────────────────────────────────────────────────

    def _read_loop(self, proc: subprocess.Popen) -> None:
        try:
            for raw_line in proc.stdout:  # type: ignore[union-attr]
                line = raw_line.strip()
                if not line:
                    continue
                if self._on_raw:
                    try:
                        self._on_raw(line)
                    except Exception:
                        pass
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                try:
                    self._handle(obj)
                except Exception:
                    logger.exception("Error handling claude event")
        finally:
            code = proc.wait()
            # Only report if this is still the active process (not a close()/restart)
            if proc is self._proc:
                logger.warning("Claude process exited unexpectedly (code=%s)", code)
                if not self._got_init and self._resume_attempted:
                    # Stale session id → --resume failed before init. Start fresh
                    # so a bad session.json can never brick the voice loop.
                    logger.info("Resume of %s failed — restarting fresh", self._resume_attempted)
                    self.session_id = None
                    self.start(None, self._work_dir)
                    self._on_event({
                        "type": "error",
                        "message": "Could not resume the previous session, so I started a new one.",
                    })
                else:
                    self._proc = None
                    self._on_event({
                        "type": "error",
                        "message": f"Claude Code exited unexpectedly (code {code}).",
                    })
                    self._on_event({"type": "status", "state": "idle"})

    def _drain_stderr(self, proc: subprocess.Popen) -> None:
        tail: list[str] = []
        try:
            for line in proc.stderr:  # type: ignore[union-attr]
                tail.append(line.rstrip())
                if len(tail) > 20:
                    tail.pop(0)
        except Exception:
            pass
        if tail and proc.poll() not in (0, None):
            logger.warning("claude stderr tail: %s", " | ".join(tail[-5:]))

    def _handle(self, obj: dict) -> None:
        typ = obj.get("type")

        if typ == "system" and obj.get("subtype") == "init":
            self._got_init = True
            sid = obj.get("session_id")
            if sid:
                self.session_id = sid
                self._on_event({"type": "session", "session_id": sid})

        elif typ == "stream_event":
            event = obj.get("event") or {}
            if event.get("type") == "content_block_delta":
                delta = event.get("delta") or {}
                if delta.get("type") == "text_delta" and delta.get("text"):
                    self._on_event({"type": "assistant_delta", "text": delta["text"]})

        elif typ == "assistant":
            content = (obj.get("message") or {}).get("content") or []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    self._on_event({
                        "type": "tool_activity",
                        "text": _tool_summary(block.get("name", "a tool"), block.get("input")),
                    })

        elif typ == "result":
            sid = obj.get("session_id") or self.session_id
            if sid:
                self.session_id = sid
            self._on_event({
                "type": "turn_done",
                "text": obj.get("result") or "",
                "session_id": sid or "",
            })
            self._on_event({"type": "status", "state": "idle"})

        # control_response / user echoes / tool results: nothing to speak.
