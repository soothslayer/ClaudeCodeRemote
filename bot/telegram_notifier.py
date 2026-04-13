"""
telegram_notifier.py
Sends a Telegram message from the bot to the user when a Claude Code response
is ready. This gives the blind friend a push notification if the iOS app is
not in the foreground.

The Telegram bot must be started by the user (they send /start once),
which registers their chat_id in chat_id.txt automatically.
"""

import httpx
import logging
import os
from pathlib import Path

logger = logging.getLogger(__name__)

BOT_TOKEN: str = os.environ.get("TELEGRAM_BOT_TOKEN", "")
_CHAT_ID_FILE = Path(__file__).parent / "chat_id.txt"


def get_chat_id() -> str | None:
    """Read the stored chat ID (written when user first messages the bot)."""
    if _CHAT_ID_FILE.exists():
        return _CHAT_ID_FILE.read_text().strip() or None
    # Fall back to environment variable for manual override
    return os.environ.get("TELEGRAM_USER_CHAT_ID", "") or None


def save_chat_id(chat_id: str | int) -> None:
    _CHAT_ID_FILE.write_text(str(chat_id))


async def send_message(text: str, chat_id: str | None = None) -> bool:
    """
    Send a Telegram message to the user.
    Returns True on success, False on failure (non-fatal).
    """
    if not BOT_TOKEN:
        logger.warning("TELEGRAM_BOT_TOKEN not set — skipping Telegram notification")
        return False

    effective_chat_id = chat_id or get_chat_id()
    if not effective_chat_id:
        logger.warning("No Telegram chat_id available — skipping notification")
        return False

    # Telegram messages are capped at 4096 chars
    truncated = text[:4000] + ("\n\n…(truncated)" if len(text) > 4000 else "")

    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
    payload = {"chat_id": effective_chat_id, "text": truncated, "parse_mode": "Markdown"}

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(url, json=payload)
            if resp.status_code != 200:
                logger.error("Telegram API error %s: %s", resp.status_code, resp.text)
                return False
        return True
    except Exception as exc:
        logger.error("Failed to send Telegram message: %s", exc)
        return False


async def poll_and_register(once: bool = False) -> None:
    """
    Long-poll Telegram for incoming messages to capture the user's chat_id
    automatically when they send /start (or any message) to the bot.

    Run this in a background task at server startup.
    """
    if not BOT_TOKEN:
        return

    offset = 0
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/getUpdates"

    while True:
        try:
            async with httpx.AsyncClient(timeout=35) as client:
                resp = await client.post(url, json={"offset": offset, "timeout": 30})
                if resp.status_code != 200:
                    import asyncio; await asyncio.sleep(5)
                    continue

                data = resp.json()
                for update in data.get("result", []):
                    offset = update["update_id"] + 1
                    msg = update.get("message", {})
                    chat_id = msg.get("chat", {}).get("id")
                    if chat_id:
                        save_chat_id(chat_id)
                        logger.info("Registered Telegram chat_id: %s", chat_id)
                        # Send confirmation
                        await send_message(
                            "✅ Claude Code Remote bot is connected! You will receive notifications here when Claude Code responds.",
                            chat_id=str(chat_id)
                        )

        except Exception as exc:
            logger.warning("Telegram poll error: %s", exc)

        if once:
            break

        import asyncio
        await asyncio.sleep(1)
