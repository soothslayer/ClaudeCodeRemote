#!/usr/bin/env python3
"""
serve_headless.py — UI-less entrypoint for the Swift menu-bar app.

menu_bar.py runs uvicorn + ngrok *and* draws a rumps menu bar.  When the
server is hosted by ClaudeCodeRemoteServer.app (the Xcode target) the menu
bar belongs to Swift, so this module provides the same supervision with no
UI at all and reports state upstream as JSON lines on stdout.

Protocol (one JSON object per line, stdout, unbuffered):

    {"event": "starting",     "port": 8080}
    {"event": "server_ready", "port": 8080}
    {"event": "ngrok_url",    "url": "https://x.ngrok-free.app"}   # or null
    {"event": "log",          "level": "INFO", "message": "..."}
    {"event": "fatal",        "message": "..."}

Anything the parent can't parse is a plain log line and is treated as such.
"""

from __future__ import annotations

import json
import logging
import logging.handlers
import os
import signal
import sys
import threading
import time
from pathlib import Path

BOT_DIR = Path(__file__).resolve().parent
if str(BOT_DIR) not in sys.path:
    sys.path.insert(0, str(BOT_DIR))

from paths import config_dir, config_file, log_dir, migrate_legacy_state  # noqa: E402
from ngrok_supervisor import NgrokSupervisor  # noqa: E402

DEFAULT_PORT = 8080
DEFAULT_WORK_DIR = "~/git/buck"

_emit_lock = threading.Lock()


def emit(event: str, **fields) -> None:
    """Write one JSON line to stdout for the Swift parent to read."""
    payload = {"event": event, **fields}
    with _emit_lock:
        try:
            sys.stdout.write(json.dumps(payload) + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, ValueError):
            # Parent went away — nothing useful left to do.
            pass


class _EmitHandler(logging.Handler):
    """Mirror log records to the parent as structured events."""

    def emit(self, record: logging.LogRecord) -> None:
        try:
            emit("log", level=record.levelname, message=self.format(record))
        except Exception:
            pass


def _configure_logging() -> None:
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")

    fh = logging.handlers.RotatingFileHandler(
        log_dir() / "server.log", maxBytes=1_000_000, backupCount=3
    )
    fh.setFormatter(fmt)
    root.addHandler(fh)

    eh = _EmitHandler()
    eh.setFormatter(fmt)
    root.addHandler(eh)


logger = logging.getLogger("serve_headless")


def _load_config() -> dict:
    p = config_file()
    if p.exists():
        try:
            return json.loads(p.read_text())
        except Exception:
            logger.exception("config.json unreadable — using defaults")
    return {"work_dir": DEFAULT_WORK_DIR}


def _get_static_domain() -> str | None:
    return (_load_config().get("ngrok_static_domain") or "").strip() or None


def _port() -> int:
    raw = os.environ.get("CLAUDE_REMOTE_PORT", "").strip()
    if raw.isdigit():
        return int(raw)
    return DEFAULT_PORT


def main() -> None:
    migrate_legacy_state()
    _configure_logging()

    port = _port()
    emit("starting", port=port)
    logger.info("headless server starting; config=%s logs=%s", config_dir(), log_dir())

    # server.py resolves some paths relative to the working directory.
    os.chdir(BOT_DIR)
    try:
        from dotenv import load_dotenv

        load_dotenv(BOT_DIR / ".env")
    except Exception:
        pass

    # A second ngrok agent would evict the first on a free account, so allow
    # the tunnel to be suppressed when testing alongside a running instance.
    tunnel_disabled = os.environ.get("CLAUDE_REMOTE_DISABLE_NGROK", "") not in ("", "0")

    supervisor = NgrokSupervisor(
        port=port,
        get_static_domain=_get_static_domain,
        on_url_change=lambda url: emit("ngrok_url", url=url),
    )

    def _shutdown(signum, _frame):
        logger.info("signal %s — shutting down", signum)
        try:
            supervisor.stop()
        except Exception:
            pass
        # uvicorn installs its own handlers; re-raising the default ends us.
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    # The Swift host terminates us on Quit, but a crash or Force Quit would
    # otherwise leave uvicorn and ngrok holding the port forever — and the next
    # launch could not bind. Watch for reparenting to launchd and stand down.
    def _watch_parent() -> None:
        original_ppid = os.getppid()
        if original_ppid <= 1:
            return  # launched standalone; nothing to watch
        while True:
            time.sleep(2)
            if os.getppid() != original_ppid:
                logger.warning("parent process exited — shutting down")
                os.kill(os.getpid(), signal.SIGTERM)
                return

    threading.Thread(target=_watch_parent, daemon=True, name="parent-watchdog").start()

    if tunnel_disabled:
        logger.info("CLAUDE_REMOTE_DISABLE_NGROK set — not starting a tunnel")
    else:
        supervisor.start()

    # Announce readiness once the socket is actually accepting.
    def _announce_ready() -> None:
        import socket

        deadline = time.time() + 30
        while time.time() < deadline:
            with socket.socket() as s:
                s.settimeout(0.5)
                if s.connect_ex(("127.0.0.1", port)) == 0:
                    emit("server_ready", port=port)
                    return
            time.sleep(0.25)
        emit("fatal", message=f"server did not bind port {port} within 30s")

    threading.Thread(target=_announce_ready, daemon=True, name="ready-probe").start()

    import uvicorn

    try:
        uvicorn.run("server:app", host="0.0.0.0", port=port, log_level="info")
    except Exception as exc:
        logger.exception("uvicorn exited")
        emit("fatal", message=str(exc))
        supervisor.stop()
        raise
    finally:
        supervisor.stop()


if __name__ == "__main__":
    main()
