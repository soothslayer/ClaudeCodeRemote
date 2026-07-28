"""
ngrok_supervisor.py — babysit the ngrok tunnel.

- Launches ngrok as a child process pointed at the local server.
- Restarts it with exponential backoff if it dies (up to 60 s).
- Uses the configured static domain when set (free ngrok tier gives one
  static domain per account, which we prefer so the magic link stays
  valid across restarts).
- Polls the local ngrok dashboard (http://127.0.0.1:4040) for the public
  URL and fires callbacks when it changes.
- Runs on a background daemon thread; safe to call .stop() from another
  thread (menu-bar quit path).
"""

from __future__ import annotations

import json
import logging
import subprocess
import threading
import time
import urllib.request
from typing import Callable

from paths import ngrok_binary

logger = logging.getLogger(__name__)

NGROK_API = "http://127.0.0.1:4040/api/tunnels"


class NgrokSupervisor:
    def __init__(
        self,
        port: int,
        get_static_domain: Callable[[], str | None],
        on_url_change: Callable[[str | None], None] | None = None,
    ) -> None:
        self._port = port
        self._get_static_domain = get_static_domain
        self._on_url_change = on_url_change

        self._proc: subprocess.Popen | None = None
        self._thread: threading.Thread | None = None
        self._stop_event = threading.Event()

        self._current_url: str | None = None
        self._launched_domain: str | None = None  # domain the running proc was started with

    # ── Lifecycle ────────────────────────────────────────────────────────────

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(
            target=self._run,
            name="ngrok-supervisor",
            daemon=True,
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        self._kill_proc()

    def current_url(self) -> str | None:
        return self._current_url

    def restart(self) -> None:
        """Kill the current ngrok process; the supervisor loop relaunches it
        with whatever config is current (used after the static domain changes)."""
        self._kill_proc()

    # ── Internals ────────────────────────────────────────────────────────────

    def _spawn(self) -> subprocess.Popen | None:
        binary = ngrok_binary()
        if binary is None:
            logger.error("ngrok binary not found — install it and retry")
            return None

        domain = (self._get_static_domain() or "").strip() or None
        cmd = [binary, "http", str(self._port)]
        if domain:
            cmd.extend(["--domain", domain])
        logger.info("Launching ngrok: %s", " ".join(cmd))
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            logger.exception("Failed to spawn ngrok")
            return None
        self._launched_domain = domain
        return proc

    def _kill_proc(self) -> None:
        proc = self._proc
        self._proc = None
        if proc is None:
            return
        try:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
        except Exception:
            pass

    def _fetch_tunnel_url(self) -> str | None:
        try:
            with urllib.request.urlopen(NGROK_API, timeout=2) as resp:
                data = json.loads(resp.read())
        except Exception:
            return None
        for tunnel in data.get("tunnels", []):
            if tunnel.get("proto") == "https":
                return tunnel.get("public_url")
        return None

    def _publish_url(self, url: str | None) -> None:
        if url == self._current_url:
            return
        self._current_url = url
        if self._on_url_change is not None:
            try:
                self._on_url_change(url)
            except Exception:
                logger.exception("on_url_change callback failed")

    def _run(self) -> None:
        backoff = 2.0
        max_backoff = 60.0

        while not self._stop_event.is_set():
            self._proc = self._spawn()
            if self._proc is None:
                if self._stop_event.wait(backoff):
                    break
                backoff = min(backoff * 2, max_backoff)
                continue

            # Discovery loop — wait for the tunnel to come up and poll while alive.
            url_backoff_reset = False
            while not self._stop_event.is_set():
                if self._proc.poll() is not None:
                    logger.warning("ngrok exited with code %s — restarting", self._proc.returncode)
                    self._publish_url(None)
                    break

                # If the configured static domain changed, restart with the new one.
                configured = (self._get_static_domain() or "").strip() or None
                if configured != self._launched_domain:
                    logger.info(
                        "ngrok static domain changed (%r → %r) — restarting",
                        self._launched_domain, configured,
                    )
                    self._kill_proc()
                    self._publish_url(None)
                    break

                url = self._fetch_tunnel_url()
                self._publish_url(url)

                if url and not url_backoff_reset:
                    backoff = 2.0
                    url_backoff_reset = True

                if self._stop_event.wait(5):
                    break

            self._kill_proc()

            if not self._stop_event.is_set():
                # Died without a healthy tunnel — back off before respawning.
                if not url_backoff_reset:
                    if self._stop_event.wait(backoff):
                        break
                    backoff = min(backoff * 2, max_backoff)

        self._publish_url(None)
