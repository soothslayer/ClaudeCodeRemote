#!/usr/bin/env python3
"""
menu_bar.py — macOS menu bar app for Claude Code Remote.

Runs the FastAPI server on a background thread and supervises ngrok in a
sibling thread.  Ships as a login-startup app (via LaunchAgent when running
from source, or via a py2app-built .app bundle installed to /Applications).

Everything a sighted caregiver needs is one click deep in the menu:
Copy Magic Link, Configure ngrok (authtoken + static domain), Open Logs.
"""

from __future__ import annotations

import json
import logging
import logging.handlers
import os
import subprocess
import sys
import threading
import webbrowser
from pathlib import Path

import rumps
import uvicorn

from paths import config_dir, config_file, log_dir, migrate_legacy_state, ngrok_binary
from ngrok_supervisor import NgrokSupervisor

BOT_DIR = Path(__file__).parent
PORT = 8080
DEFAULT_WORK_DIR = "~/git/buck"


# ── Logging ───────────────────────────────────────────────────────────────────

def _configure_logging() -> None:
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    # Rotating file so a stuck loop can't fill the disk.
    fh = logging.handlers.RotatingFileHandler(
        log_dir() / "menu_bar.log",
        maxBytes=1_000_000,
        backupCount=3,
    )
    fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root.addHandler(fh)
    # Also mirror to stderr so LaunchAgent logs still catch startup failures.
    sh = logging.StreamHandler()
    sh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root.addHandler(sh)


logger = logging.getLogger("menu_bar")


# ── Config accessors ──────────────────────────────────────────────────────────

def _load_config() -> dict:
    p = config_file()
    if p.exists():
        try:
            return json.loads(p.read_text())
        except Exception:
            logger.exception("config.json unreadable — using defaults")
    return {"work_dir": DEFAULT_WORK_DIR}


def _save_config(cfg: dict) -> None:
    config_file().write_text(json.dumps(cfg, indent=2))


def _get_static_domain() -> str | None:
    return (_load_config().get("ngrok_static_domain") or "").strip() or None


# ── Server thread ─────────────────────────────────────────────────────────────

def _start_server() -> None:
    """Run uvicorn in the calling thread (must be a daemon thread)."""
    os.chdir(BOT_DIR)
    if str(BOT_DIR) not in sys.path:
        sys.path.insert(0, str(BOT_DIR))
    try:
        from dotenv import load_dotenv
        load_dotenv(BOT_DIR / ".env")
    except Exception:
        pass
    uvicorn.run("server:app", host="0.0.0.0", port=PORT, log_level="info")


# ── ngrok authtoken helper ────────────────────────────────────────────────────

def _set_ngrok_authtoken(token: str) -> tuple[bool, str]:
    binary = ngrok_binary()
    if binary is None:
        return False, "ngrok binary not found."
    try:
        result = subprocess.run(
            [binary, "config", "add-authtoken", token],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except Exception as exc:
        return False, f"Failed to run ngrok: {exc}"
    if result.returncode != 0:
        return False, (result.stderr or result.stdout or "ngrok reported an error.").strip()
    return True, "Authtoken saved."


# ── Menu bar app ──────────────────────────────────────────────────────────────

class ClaudeRemoteApp(rumps.App):
    def __init__(self):
        super().__init__(
            "☁",
            menu=[
                rumps.MenuItem("Status: starting…"),
                None,
                rumps.MenuItem("Copy Magic Link",       callback=self.copy_magic_link),
                rumps.MenuItem("Open QR Page",          callback=self.open_qr_page),
                rumps.MenuItem("Open Activity Window",  callback=self.open_activity),
                None,
                rumps.MenuItem("Configure ngrok…",      callback=self.configure_ngrok),
                rumps.MenuItem("Reveal Logs in Finder", callback=self.reveal_logs),
                rumps.MenuItem("Restart",               callback=self.restart_app),
                rumps.MenuItem("Quit",                  callback=self.quit_app),
            ],
            quit_button=None,
        )
        migrate_legacy_state()

        self._ngrok_url: str | None = None

        # 1. Uvicorn on a daemon thread (dies with the process)
        threading.Thread(target=_start_server, daemon=True, name="uvicorn").start()

        # 2. Supervised ngrok
        self._supervisor = NgrokSupervisor(
            port=PORT,
            get_static_domain=_get_static_domain,
            on_url_change=self._on_url_change,
        )
        self._supervisor.start()

        # 3. UI refresh timer (updates label if the URL changes)
        self._ui_timer = rumps.Timer(self._refresh_ui, 2)
        self._ui_timer.start()

    # ── Supervisor callback ───────────────────────────────────────────────────

    def _on_url_change(self, url: str | None) -> None:
        # Called from the supervisor thread — never touch rumps UI from here.
        self._ngrok_url = url
        if url:
            logger.info("ngrok tunnel: %s", url)
        else:
            logger.info("ngrok tunnel: down")

    def _refresh_ui(self, _sender):
        if self._ngrok_url:
            self.menu["Status: starting…"].title = "Status: running ✓"
            self.title = "☁✓"
        else:
            self.menu["Status: starting…"].title = "Status: waiting for ngrok…"
            self.title = "☁"

    # ── Menu callbacks ────────────────────────────────────────────────────────

    def copy_magic_link(self, _sender):
        if not self._ngrok_url:
            rumps.alert(
                title="Not ready yet",
                message="ngrok hasn't connected yet. Wait a few seconds and try again.",
            )
            return
        magic = f"clauderemote://setup?url={self._ngrok_url}"
        try:
            subprocess.run(["pbcopy"], input=magic.encode(), check=True)
        except Exception:
            logger.exception("pbcopy failed")
            rumps.alert(title="Copy failed", message="Could not copy to clipboard.")
            return
        rumps.notification(
            title="Magic Link Copied ✓",
            subtitle="",
            message="Paste it into iMessage to send to your friend.",
        )

    def open_qr_page(self, _sender):
        webbrowser.open(f"http://localhost:{PORT}/qr")

    def open_activity(self, _sender):
        webbrowser.open(f"http://localhost:{PORT}/activity")

    def configure_ngrok(self, _sender):
        """Prompt for authtoken (one-time) and static domain (persisted)."""
        current_domain = _get_static_domain() or ""

        token_win = rumps.Window(
            title="ngrok authtoken",
            message=(
                "Paste your ngrok authtoken (get it from "
                "https://dashboard.ngrok.com/get-started/your-authtoken).\n"
                "Leave blank to keep the current one."
            ),
            default_text="",
            ok="Save",
            cancel="Skip",
            dimensions=(320, 24),
        )
        token_res = token_win.run()
        if token_res.clicked and token_res.text.strip():
            ok, msg = _set_ngrok_authtoken(token_res.text.strip())
            if not ok:
                rumps.alert(title="Authtoken not saved", message=msg)
                return

        domain_win = rumps.Window(
            title="ngrok static domain",
            message=(
                "Set your free static domain (e.g. your-name.ngrok-free.app) "
                "so the magic link stays valid across restarts.\n"
                "Claim one at https://dashboard.ngrok.com → Domains.\n"
                "Leave blank to use a fresh random URL each time."
            ),
            default_text=current_domain,
            ok="Save",
            cancel="Cancel",
            dimensions=(320, 24),
        )
        domain_res = domain_win.run()
        if not domain_res.clicked:
            return

        cfg = _load_config()
        cfg["ngrok_static_domain"] = domain_res.text.strip()
        _save_config(cfg)
        logger.info("ngrok static domain set to %r — restarting tunnel", cfg["ngrok_static_domain"])
        self._supervisor.restart()

    def reveal_logs(self, _sender):
        subprocess.run(["open", str(log_dir())], check=False)

    def restart_app(self, _sender):
        """Quit cleanly — the LaunchAgent's KeepAlive:true will relaunch us."""
        self._supervisor.stop()
        rumps.quit_application()

    def quit_app(self, _sender):
        """Quit permanently — bootout the LaunchAgent so it doesn't relaunch."""
        try:
            plist = Path.home() / "Library/LaunchAgents/com.claudecoderemote.menubar.plist"
            subprocess.run(
                ["launchctl", "bootout", f"gui/{os.getuid()}", str(plist)],
                check=False,
            )
        except Exception:
            pass
        self._supervisor.stop()
        rumps.quit_application()


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    _configure_logging()
    logger.info("Claude Code Remote menu bar starting; config=%s logs=%s",
                config_dir(), log_dir())
    ClaudeRemoteApp().run()


if __name__ == "__main__":
    main()
