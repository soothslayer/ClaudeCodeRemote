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
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from claude_runner import run_claude

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

@app.post("/session/new")
async def new_session(req: NewSessionRequest):
    """Start a fresh Claude Code session."""
    logger.info("New session: %s…", req.prompt[:80])
    try:
        response, session_id = await asyncio.to_thread(run_claude, req.prompt, None)
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    save_session(session_id, response)
    return {"session_id": session_id, "response": response}


@app.post("/session/message")
async def send_message_endpoint(req: MessageRequest):
    """Send a follow-up message in an existing session."""
    logger.info("Message in session %s: %s…", req.session_id, req.prompt[:80])
    try:
        response, session_id = await asyncio.to_thread(run_claude, req.prompt, req.session_id)
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


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run("server:app", host="0.0.0.0", port=port, reload=False)
