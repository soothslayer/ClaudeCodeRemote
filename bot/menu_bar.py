#!/usr/bin/env python3
"""
menu_bar.py — macOS menu bar app for Claude Code Remote.
Starts the FastAPI server + ngrok at login; puts a status icon in the menu bar.

Install as a login item with setup.sh, then forget about it — it auto-starts
every time you log in.
"""

import json
import os
import subprocess
import sys
import threading
import urllib.request
import webbrowser
from pathlib import Path

import rumps
import uvicorn

BOT_DIR = Path(__file__).parent
PORT = 8080
NGROK_API = "http://localhost:4040/api/tunnels"


# ── Helpers ───────────────────────────────────────────────────────────────────

def _start_server() -> None:
    """Run uvicorn in the calling thread (must be a daemon thread)."""
    os.chdir(BOT_DIR)
    if str(BOT_DIR) not in sys.path:
        sys.path.insert(0, str(BOT_DIR))
    from dotenv import load_dotenv
    load_dotenv(BOT_DIR / ".env")
    uvicorn.run("server:app", host="0.0.0.0", port=PORT, log_level="info")


def _start_ngrok() -> subprocess.Popen:
    """Launch ngrok http <PORT> as a child process."""
    return subprocess.Popen(
        ["ngrok", "http", str(PORT)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _get_ngrok_url() -> str | None:
    """Query the ngrok local dashboard API; return the public https:// URL or None."""
    try:
        with urllib.request.urlopen(NGROK_API, timeout=2) as resp:
            data = json.loads(resp.read())
        for tunnel in data.get("tunnels", []):
            if tunnel.get("proto") == "https":
                return tunnel["public_url"]
    except Exception:
        pass
    return None


# ── Menu bar app ──────────────────────────────────────────────────────────────

class ClaudeRemoteApp(rumps.App):
    def __init__(self):
        super().__init__(
            "☁",
            menu=[
                rumps.MenuItem("Status: starting…"),
                None,  # separator
                rumps.MenuItem("Copy Magic Link",      callback=self.copy_magic_link),
                rumps.MenuItem("Open QR Page",         callback=self.open_qr_page),
                rumps.MenuItem("Open Activity Window", callback=self.open_activity),
                None,  # separator
                rumps.MenuItem("Quit", callback=self.quit_app),
            ],
            quit_button=None,  # custom Quit so we can clean up ngrok
        )
        self._ngrok_url: str | None = None
        self._ngrok_proc: subprocess.Popen | None = None

        # Disable menu items until we have a URL
        self.menu["Copy Magic Link"].set_callback(self.copy_magic_link)

        # 1. Start uvicorn on a daemon thread (dies with the process)
        server_thread = threading.Thread(target=_start_server, daemon=True, name="uvicorn")
        server_thread.start()

        # 2. Start ngrok
        self._ngrok_proc = _start_ngrok()

        # 3. Poll ngrok API every 5 s to discover the public URL
        self._poll_timer = rumps.Timer(self._poll_status, 5)
        self._poll_timer.start()

    # ── Polling ───────────────────────────────────────────────────────────────

    def _poll_status(self, _sender):
        url = _get_ngrok_url()
        if url and url != self._ngrok_url:
            self._ngrok_url = url
            self.menu["Status: starting…"].title = "Status: running ✓"
            self.title = "☁✓"
        elif not url and self._ngrok_url is None:
            # Still starting — keep spinner text as-is
            pass

    # ── Menu callbacks ────────────────────────────────────────────────────────

    def copy_magic_link(self, _sender):
        if not self._ngrok_url:
            rumps.alert(
                title="Not ready yet",
                message="ngrok hasn't connected yet. Wait a few seconds and try again.",
            )
            return
        magic = f"clauderemote://setup?url={self._ngrok_url}"
        subprocess.run(["pbcopy"], input=magic.encode(), check=True)
        rumps.notification(
            title="Magic Link Copied ✓",
            subtitle="",
            message="Paste it into iMessage to send to your friend.",
        )

    def open_qr_page(self, _sender):
        webbrowser.open(f"http://localhost:{PORT}/qr")

    def open_activity(self, _sender):
        webbrowser.open(f"http://localhost:{PORT}/activity")

    def quit_app(self, _sender):
        if self._ngrok_proc:
            try:
                self._ngrok_proc.terminate()
            except Exception:
                pass
        rumps.quit_application()


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    ClaudeRemoteApp().run()
