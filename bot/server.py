"""
server.py — Claude Code Remote bot server
Runs on the user's computer. Receives requests from the iOS app, executes
them via Claude Code, and sends responses back.

Usage:
    cd bot/
    uvicorn server:app --host 0.0.0.0 --port 8080
"""

import asyncio
import json
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path

import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

from claude_runner import start_claude, collect_claude, kill_claude

# ── Config ────────────────────────────────────────────────────────────────────
load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

SESSION_FILE = Path(__file__).parent / "session.json"

# ── Lifecycle ─────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    yield

app = FastAPI(title="Claude Code Remote", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Session persistence ───────────────────────────────────────────────────────

def load_session() -> dict:
    if SESSION_FILE.exists():
        try:
            return json.loads(SESSION_FILE.read_text())
        except Exception:
            pass
    return {}


def save_session(session_id: str, last_response: str = "") -> None:
    SESSION_FILE.write_text(json.dumps({
        "session_id": session_id,
        "last_response": last_response,
    }))


# ── Request / response models ─────────────────────────────────────────────────

class NewSessionRequest(BaseModel):
    prompt: str


class MessageRequest(BaseModel):
    session_id: str
    prompt: str


# ── Endpoints ─────────────────────────────────────────────────────────────────

async def _run_claude_cancellable(
    request: Request,
    prompt: str,
    session_id: str | None,
) -> tuple[str, str]:
    """
    Run a Claude Code subprocess and kill it if the HTTP client disconnects.

    Polls request.is_disconnected() every 0.5 s while collect_claude() runs
    in a thread pool.  Returns (response_text, session_id).
    Raises HTTPException(499) on client cancel, RuntimeError on Claude error.
    """
    loop = asyncio.get_event_loop()
    proc = start_claude(prompt, session_id)
    fut = loop.run_in_executor(None, collect_claude, proc, session_id)

    try:
        while not fut.done():
            if await request.is_disconnected():
                logger.info("Client disconnected — killing Claude subprocess (pid=%d)", proc.pid)
                kill_claude(proc)
                fut.cancel()
                raise HTTPException(status_code=499, detail="Cancelled by client")
            await asyncio.sleep(0.5)

        return await fut

    except HTTPException:
        raise
    except RuntimeError:
        raise
    except Exception as exc:
        kill_claude(proc)
        raise RuntimeError(str(exc)) from exc


@app.post("/session/new")
async def new_session(req: NewSessionRequest, request: Request):
    """Start a fresh Claude Code session."""
    logger.info("New session: %s…", req.prompt[:80])
    try:
        response, session_id = await _run_claude_cancellable(request, req.prompt, None)
    except HTTPException:
        raise
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    save_session(session_id, response)
    return {"session_id": session_id, "response": response}


@app.post("/session/message")
async def send_message_endpoint(req: MessageRequest, request: Request):
    """Send a follow-up message in an existing session."""
    logger.info("Message in session %s: %s…", req.session_id, req.prompt[:80])
    try:
        response, session_id = await _run_claude_cancellable(request, req.prompt, req.session_id)
    except HTTPException:
        raise
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    save_session(session_id, response)
    return {"session_id": session_id, "response": response}


@app.get("/session/info")
async def session_info():
    """Returns current session state."""
    data = load_session()
    return {
        "has_session": bool(data.get("session_id")),
        "session_id": data.get("session_id"),
    }


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/qr", response_class=HTMLResponse)
async def qr_page():
    """
    Open http://localhost:8080/qr in a browser, paste the ngrok URL,
    and a QR code appears for the blind user to scan with the iOS app.
    """
    return HTMLResponse("""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Claude Code Remote — Server URL QR Code</title>
  <style>
    body { font-family: -apple-system, sans-serif; text-align: center;
           padding: 48px 24px; background: #111; color: #eee; }
    h1   { font-size: 1.4rem; margin-bottom: 8px; }
    p    { color: #aaa; margin-bottom: 24px; }
    input { width: 420px; max-width: 90vw; padding: 12px; font-size: 16px;
            border-radius: 8px; border: 1px solid #444; background: #222;
            color: #eee; outline: none; }
    input:focus { border-color: #0af; }
    #canvas-wrap { margin-top: 32px; }
    canvas { border-radius: 12px; }
  </style>
</head>
<body>
  <h1>Claude Code Remote — Setup QR Code</h1>
  <p>Paste the ngrok URL below. Show the QR code to your friend to scan in the app.</p>
  <input id="url" type="url" placeholder="https://xxxx.ngrok-free.app"
         oninput="update()" autocomplete="off" spellcheck="false">
  <div id="canvas-wrap"><canvas id="qr"></canvas></div>
  <script src="https://cdn.jsdelivr.net/npm/qrcode@1.5.4/build/qrcode.min.js"></script>
  <script>
    function update() {
      var val = document.getElementById('url').value.trim();
      var canvas = document.getElementById('qr');
      if (!val) { var ctx = canvas.getContext('2d'); ctx.clearRect(0,0,canvas.width,canvas.height); return; }
      QRCode.toCanvas(canvas, val, { width: 320, margin: 2,
        color: { dark: '#000000', light: '#ffffff' } }, function(){});
    }
  </script>
</body>
</html>""")



# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run("server:app", host="0.0.0.0", port=port, reload=False)
