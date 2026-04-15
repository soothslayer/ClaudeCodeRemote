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
from fastapi.responses import HTMLResponse, StreamingResponse
from pydantic import BaseModel

from claude_runner import start_claude, collect_claude, kill_claude

# ── Activity-window SSE broadcast ─────────────────────────────────────────────
# Each connected /activity/stream client gets its own asyncio.Queue.
# collect_claude runs in a thread and calls _broadcast() for every stdout line.

_activity_clients: set[asyncio.Queue] = set()
_event_loop: asyncio.AbstractEventLoop | None = None


def _broadcast(line: str) -> None:
    """Thread-safe push of a raw Claude stdout line to all SSE clients."""
    if _event_loop is None or not _activity_clients:
        return
    for q in list(_activity_clients):
        _event_loop.call_soon_threadsafe(q.put_nowait, line)

# ── Config ────────────────────────────────────────────────────────────────────
load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

SESSION_FILE = Path(__file__).parent / "session.json"
CONFIG_FILE  = Path(__file__).parent / "config.json"

DEFAULT_WORK_DIR = "~/git/buck"

# ── Lifecycle ─────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    global _event_loop
    _event_loop = asyncio.get_event_loop()
    yield

app = FastAPI(title="Claude Code Remote", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Server config persistence ─────────────────────────────────────────────────

def load_config() -> dict:
    if CONFIG_FILE.exists():
        try:
            return json.loads(CONFIG_FILE.read_text())
        except Exception:
            pass
    return {"work_dir": DEFAULT_WORK_DIR}


def save_config(config: dict) -> None:
    CONFIG_FILE.write_text(json.dumps(config, indent=2))


def get_work_dir() -> str:
    """Return the configured working directory (always fresh from disk)."""
    return load_config().get("work_dir", DEFAULT_WORK_DIR)


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


class ActivitySendRequest(BaseModel):
    prompt: str


class UpdateSettingsRequest(BaseModel):
    work_dir: str


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
    proc = start_claude(prompt, session_id, work_dir=get_work_dir())
    fut = loop.run_in_executor(None, collect_claude, proc, session_id, _broadcast)

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
    _broadcast(json.dumps({"type": "user", "text": req.prompt, "source": "ios"}))
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
    _broadcast(json.dumps({"type": "user", "text": req.prompt, "source": "ios"}))
    try:
        response, session_id = await _run_claude_cancellable(request, req.prompt, req.session_id)
    except HTTPException:
        raise
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    save_session(session_id, response)
    return {"session_id": session_id, "response": response}


@app.post("/activity/send")
async def activity_send(req: ActivitySendRequest, request: Request):
    """Send a message to Claude directly from the activity window browser tab."""
    data = load_session()
    session_id = data.get("session_id")  # None → starts a new session
    logger.info("Activity send (session=%s): %s…", session_id, req.prompt[:80])
    _broadcast(json.dumps({"type": "user", "text": req.prompt, "source": "operator"}))
    try:
        response, new_session_id = await _run_claude_cancellable(request, req.prompt, session_id)
    except HTTPException:
        raise
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    save_session(new_session_id, response)
    return {"session_id": new_session_id, "response": response}


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


@app.get("/settings")
async def get_settings():
    """Return current server-side settings."""
    config = load_config()
    return {"work_dir": config.get("work_dir", DEFAULT_WORK_DIR)}


@app.post("/settings")
async def update_settings(req: UpdateSettingsRequest):
    """Update server-side settings."""
    work_dir = req.work_dir.strip()
    if not work_dir:
        raise HTTPException(status_code=400, detail="work_dir cannot be empty")
    config = load_config()
    config["work_dir"] = work_dir
    save_config(config)
    logger.info("Settings updated: work_dir=%s", work_dir)
    return {"work_dir": work_dir}


@app.get("/ngrok-url")
async def ngrok_url_endpoint():
    """Return the current public ngrok HTTPS URL by querying the local ngrok API."""
    import urllib.request as _ur
    import json as _json
    try:
        with _ur.urlopen("http://localhost:4040/api/tunnels", timeout=2) as r:
            data = _json.loads(r.read())
        for tunnel in data.get("tunnels", []):
            if tunnel.get("proto") == "https":
                return {"url": tunnel["public_url"]}
    except Exception:
        pass
    return {"url": None}


@app.get("/activity/stream")
async def activity_stream(request: Request):
    """
    Server-Sent Events stream of every raw JSON line Claude Code emits.
    The browser /activity page consumes this to render a live activity window.
    """
    q: asyncio.Queue = asyncio.Queue()
    _activity_clients.add(q)
    logger.info("Activity client connected (%d total)", len(_activity_clients))

    async def event_generator():
        try:
            while True:
                if await request.is_disconnected():
                    break
                try:
                    line = await asyncio.wait_for(q.get(), timeout=15.0)
                    # SSE format: "data: <payload>\n\n"
                    yield f"data: {line}\n\n"
                except asyncio.TimeoutError:
                    # Keepalive ping so the connection stays open
                    yield ": ping\n\n"
        finally:
            _activity_clients.discard(q)
            logger.info("Activity client disconnected (%d remaining)", len(_activity_clients))

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


@app.get("/activity", response_class=HTMLResponse)
async def activity_page():
    """Live activity window — shows Claude Code thinking and responding in real time."""
    return HTMLResponse("""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Claude Code Remote — Activity</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { background: #0d1117; color: #e6edf3; font-family: 'SF Mono', 'Fira Code', monospace;
           font-size: 13px; line-height: 1.6; display: flex; flex-direction: column; height: 100vh; }
    header { padding: 12px 20px; background: #161b22; border-bottom: 1px solid #30363d;
             display: flex; align-items: center; gap: 12px; flex-shrink: 0; }
    header h1 { font-size: 14px; font-weight: 600; color: #58a6ff; }
    #status-dot { width: 10px; height: 10px; border-radius: 50%; background: #3fb950;
                  box-shadow: 0 0 6px #3fb950; transition: background .3s; flex-shrink: 0; }
    #status-dot.idle { background: #6e7681; box-shadow: none; }
    #status-dot.working { background: #f0883e; box-shadow: 0 0 6px #f0883e;
                          animation: pulse 1.2s ease-in-out infinite; }
    @keyframes pulse { 0%,100% { opacity:1 } 50% { opacity:.4 } }
    #status-text { color: #8b949e; font-size: 12px; }
    #log { flex: 1; overflow-y: auto; padding: 16px 20px; }
    .entry { margin-bottom: 14px; }
    .ts { color: #484f58; font-size: 11px; margin-bottom: 2px; }
    .bubble { padding: 8px 12px; border-radius: 8px; white-space: pre-wrap; word-break: break-word; }
    .assistant    .bubble { background: #1c2128; border-left: 3px solid #58a6ff; color: #e6edf3; }
    .tool-use     .bubble { background: #161b22; border-left: 3px solid #f0883e; color: #ffa657; }
    .tool-result  .bubble { background: #161b22; border-left: 3px solid #3fb950; color: #7ee787; }
    .result       .bubble { background: #1c2128; border-left: 3px solid #bc8cff; color: #d2a8ff;
                            font-family: -apple-system, sans-serif; font-size: 13px; }
    .error        .bubble { background: #1c1010; border-left: 3px solid #f85149; color: #f85149; }
    .user-ios     .bubble { background: #0d2b1a; border-left: 3px solid #3fb950; color: #7ee787; }
    .user-operator .bubble { background: #0d1f2e; border-left: 3px solid #58a6ff; color: #79c0ff; }
    .label { font-size: 11px; font-weight: 600; margin-bottom: 3px; opacity: .7; }
    #empty { color: #484f58; text-align: center; margin-top: 80px; font-size: 13px; }
    #clear-btn { margin-left: auto; padding: 4px 10px; background: #21262d; border: 1px solid #30363d;
                 color: #8b949e; border-radius: 6px; cursor: pointer; font-size: 12px; }
    #clear-btn:hover { background: #30363d; color: #e6edf3; }
    #send-bar { padding: 12px 20px; background: #161b22; border-top: 1px solid #30363d;
                display: flex; gap: 10px; flex-shrink: 0; align-items: flex-end; }
    #send-input { flex: 1; padding: 8px 12px; background: #0d1117; border: 1px solid #30363d;
                  border-radius: 8px; color: #e6edf3; font-family: inherit; font-size: 13px;
                  resize: none; min-height: 38px; max-height: 120px; outline: none; }
    #send-input:focus { border-color: #58a6ff; }
    #send-btn { padding: 8px 18px; background: #238636; border: none; border-radius: 8px;
                color: #fff; font-weight: 600; cursor: pointer; white-space: nowrap; height: 38px; }
    #send-btn:disabled { background: #21262d; color: #484f58; cursor: not-allowed; }
    #send-btn:not(:disabled):hover { background: #2ea043; }
  </style>
</head>
<body>
  <header>
    <div id="status-dot" class="idle"></div>
    <h1>Claude Code Remote</h1>
    <span id="status-text">Waiting for activity…</span>
    <button id="clear-btn" onclick="clearLog()">Clear</button>
  </header>
  <div id="log"><div id="empty">No activity yet — waiting for a prompt from the iOS app or type below.</div></div>
  <div id="send-bar">
    <textarea id="send-input" placeholder="Type a message to Claude… (Enter to send, Shift+Enter for newline)"
              onkeydown="handleKey(event)" rows="1"></textarea>
    <button id="send-btn" onclick="sendMessage()">Send</button>
  </div>

  <script>
    var log = document.getElementById('log');
    var dot = document.getElementById('status-dot');
    var statusText = document.getElementById('status-text');
    var empty = document.getElementById('empty');
    var isSending = false;

    function setStatus(state, text) {
      dot.className = state;
      statusText.textContent = text;
    }

    function ts() {
      return new Date().toLocaleTimeString();
    }

    function append(cls, label, text) {
      if (empty) { empty.remove(); empty = null; }
      var entry = document.createElement('div');
      entry.className = 'entry ' + cls;
      entry.innerHTML =
        '<div class="ts">' + ts() + '</div>' +
        '<div class="label">' + label + '</div>' +
        '<div class="bubble">' + escHtml(text) + '</div>';
      log.appendChild(entry);
      log.scrollTop = log.scrollHeight;
    }

    function escHtml(s) {
      return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }

    function clearLog() {
      log.innerHTML = '<div id="empty">Log cleared.</div>';
      empty = document.getElementById('empty');
    }

    function handleLine(raw) {
      var obj;
      try { obj = JSON.parse(raw); } catch(e) { return; }

      var type = obj.type || '';

      if (type === 'user') {
        var cls   = obj.source === 'operator' ? 'user-operator' : 'user-ios';
        var label = obj.source === 'operator' ? '🧑\u200d💻 You (browser)' : '📱 Friend (iOS)';
        append(cls, label, obj.text || '');
        setStatus('working', 'Claude is thinking…');
      } else if (type === 'assistant') {
        setStatus('working', 'Claude is responding…');
        var content = (obj.message && obj.message.content) || [];
        content.forEach(function(block) {
          if (block.type === 'text' && block.text) {
            append('assistant', '🤖 Claude', block.text.trim());
          } else if (block.type === 'tool_use') {
            var input = JSON.stringify(block.input || {}, null, 2);
            append('tool-use', '🔧 Tool call: ' + block.name, input);
          }
        });
      } else if (type === 'tool') {
        setStatus('working', 'Running tool…');
        var content = obj.content || [];
        var parts = content.map(function(c) {
          if (c.type === 'text') return c.text;
          return JSON.stringify(c);
        }).join('\\n');
        if (parts.length > 1200) parts = parts.slice(0, 1200) + '\\n… (truncated)';
        append('tool-result', '📤 Tool result', parts);
      } else if (type === 'result') {
        setStatus('idle', 'Done');
        append('result', '✅ Final response', obj.result || '');
      } else if (type === 'error') {
        setStatus('idle', 'Error');
        append('error', '❌ Error', obj.error || raw);
      } else if (type === 'system' && obj.subtype === 'init') {
        setStatus('working', 'Session started');
        append('assistant', '⚡ Session init', 'tools: ' + ((obj.tools || []).map(function(t){ return t.name; }).join(', ') || '(none)'));
      }
    }

    // ── Send from browser ──────────────────────────────────────────────────────

    function handleKey(e) {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
    }

    function sendMessage() {
      var input = document.getElementById('send-input');
      var btn   = document.getElementById('send-btn');
      var text  = input.value.trim();
      if (!text || isSending) return;

      isSending = true;
      btn.disabled = true;
      input.value = '';
      input.style.height = '';

      fetch('/activity/send', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({prompt: text})
      })
      .then(function(r) {
        if (!r.ok) return r.json().then(function(d) { throw new Error(d.detail || r.statusText); });
      })
      .catch(function(err) { append('error', '❌ Send error', String(err)); })
      .finally(function() { isSending = false; btn.disabled = false; input.focus(); });
    }

    // ── SSE connection ─────────────────────────────────────────────────────────

    function connect() {
      var es = new EventSource('/activity/stream');
      es.onmessage = function(e) { handleLine(e.data); };
      es.onerror = function() {
        setStatus('idle', 'Reconnecting…');
        es.close();
        setTimeout(connect, 3000);
      };
    }
    connect();
  </script>
</body>
</html>""")


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
  <title>Claude Code Remote — Setup</title>
  <style>
    body { font-family: -apple-system, sans-serif; text-align: center;
           padding: 48px 24px; background: #111; color: #eee; max-width: 600px; margin: 0 auto; }
    h1   { font-size: 1.4rem; margin-bottom: 8px; }
    p    { color: #aaa; margin-bottom: 24px; }
    input { width: 100%; box-sizing: border-box; padding: 12px; font-size: 16px;
            border-radius: 8px; border: 1px solid #444; background: #222;
            color: #eee; outline: none; }
    input:focus { border-color: #0af; }
    .section { margin-top: 36px; text-align: left; }
    .section h2 { font-size: 1rem; color: #0af; margin-bottom: 8px; }
    .link-box { display: flex; gap: 8px; align-items: center; margin-top: 8px; }
    .link-text { flex: 1; padding: 10px 12px; background: #1a1a2e; border: 1px solid #333;
                 border-radius: 8px; font-size: 13px; color: #7af; word-break: break-all;
                 min-height: 40px; }
    button { padding: 10px 18px; background: #0af; color: #000; border: none;
             border-radius: 8px; font-size: 14px; font-weight: 600; cursor: pointer;
             white-space: nowrap; }
    button:active { background: #08d; }
    #canvas-wrap { margin-top: 16px; }
    canvas { border-radius: 12px; }
    .hint { font-size: 12px; color: #666; margin-top: 8px; }
    #status { height: 20px; color: #4c4; font-size: 13px; margin-top: 6px; }
  </style>
</head>
<body>
  <h1>Claude Code Remote — Setup</h1>
  <p>Paste the ngrok URL to generate a magic link and QR code for your friend.</p>

  <input id="url" type="url" placeholder="https://xxxx.ngrok-free.app"
         oninput="update()" autocomplete="off" spellcheck="false">
  <div id="status"></div>

  <!-- Magic link section -->
  <div class="section" id="link-section" style="display:none">
    <h2>📱 Magic Link — easiest for blind users</h2>
    <p style="font-size:13px;color:#aaa;margin-bottom:4px">
      Text this link to your friend. Tapping it opens the app and connects automatically — no Settings needed.
    </p>
    <div class="link-box">
      <div class="link-text" id="magic-link"></div>
      <button onclick="copyLink()">Copy</button>
    </div>
    <p class="hint">Works in iMessage, WhatsApp, email, etc.</p>
  </div>

  <!-- QR code section -->
  <div class="section" id="qr-section" style="display:none">
    <h2>📷 QR Code — for users who can scan</h2>
    <p style="font-size:13px;color:#aaa;margin-bottom:4px">
      Show this QR code or let them scan it with the app's built-in scanner (long press → Settings → Scan QR Code).
    </p>
    <div id="canvas-wrap"><canvas id="qr"></canvas></div>
  </div>

  <script src="https://cdn.jsdelivr.net/npm/qrcode@1.5.4/build/qrcode.min.js"></script>
  <script>
    function update() {
      var val = document.getElementById('url').value.trim();
      var linkSection = document.getElementById('link-section');
      var qrSection   = document.getElementById('qr-section');
      var magicEl     = document.getElementById('magic-link');
      var status      = document.getElementById('status');
      var canvas      = document.getElementById('qr');

      if (!val || !val.startsWith('http')) {
        linkSection.style.display = 'none';
        qrSection.style.display   = 'none';
        status.textContent = '';
        var ctx = canvas.getContext('2d');
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        return;
      }

      // Build magic link
      var magic = 'clauderemote://setup?url=' + encodeURIComponent(val);
      magicEl.textContent = magic;
      linkSection.style.display = 'block';
      qrSection.style.display   = 'block';
      status.textContent = '✓ Ready';

      // QR code encodes the magic link so scanning it also auto-connects
      QRCode.toCanvas(canvas, magic, { width: 320, margin: 2,
        color: { dark: '#000000', light: '#ffffff' } }, function(){});
    }

    // Auto-populate the URL field from the running ngrok tunnel (if any)
    window.addEventListener('load', function() {
      fetch('/ngrok-url')
        .then(function(r) { return r.json(); })
        .then(function(data) {
          if (data.url) {
            document.getElementById('url').value = data.url;
            update();
          }
        })
        .catch(function() {});  // silently ignore if server can't reach ngrok
    });

    function copyLink() {
      var text = document.getElementById('magic-link').textContent;
      navigator.clipboard.writeText(text).then(function() {
        document.getElementById('status').textContent = '✓ Copied to clipboard!';
        setTimeout(function(){ document.getElementById('status').textContent = '✓ Ready'; }, 2000);
      });
    }
  </script>
</body>
</html>""")



# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run("server:app", host="0.0.0.0", port=port, reload=False)
