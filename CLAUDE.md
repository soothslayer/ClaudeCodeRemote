# Claude Code Remote — Project Guide

Voice-only iOS app that lets a blind user hold a full-duplex, interruptible
conversation with Claude Code running on a remote computer. A Python bot
server bridges the phone to the Claude CLI; Telegram is retained for push
notifications when the app is fully backgrounded.

---

## Architecture

```
iPhone (iOS app)                        Mac (bot/)
────────────────                        ──────────
AVAudioEngine (voice-processed I/O)     FastAPI server (server.py)
 ├─ mic tap ──► SFSpeech (continuous)    ├─ /ws  (WebSocket, JSON, v1)
 │               ▼                       │       ▲            │
 │        RealtimeClient (WS) ──────────►│  user_text /       │
 │               ▲                       │  interrupt         ▼
 │  session / assistant_delta / ◄────────┤              claude_session.py
 │  tool_activity / turn_done / status   │              persistent process:
 ▼                                       │              claude --print
AVSpeechSynthesizer.write() → PCM        │                --input-format stream-json
  → AVAudioPlayerNode (same engine,      │                --output-format stream-json
    so AEC cancels TTS from mic)         │                --include-partial-messages
                                         │
                                         └─ HTTP endpoints kept for legacy
                                            /session/new /message /info /cancel
                                            (also serves /activity, /qr)

                                         telegram_notifier.py — push only
```

**Key design decisions:**
- **Full duplex:** iOS `AVAudioEngine` with `setVoiceProcessingEnabled(true)` on the input node gives hardware echo cancellation, so the mic can stay open while TTS plays. Both mic tap and playback (`AVAudioPlayerNode`) live on the same engine — TTS is rendered offline via `AVSpeechSynthesizer.write(_:)` into PCM and scheduled on the player node, giving the AEC an accurate reference signal and letting `playerNode.stop()` provide instant barge-in.
- **Streaming:** the server keeps ONE long-lived Claude subprocess (`claude_session.py`) per conversation. It emits `stream_event` deltas which the server normalizes into `assistant_delta` WebSocket events; the phone speaks each completed sentence as it arrives instead of waiting for the whole turn.
- **Interrupts:** speech in the middle of a turn is sent as `user_text` steering (the CLI accepts stream-json input mid-run). Saying only "stop"/"cancel" — or long-pressing 0.8 s — sends a `control_request:{subtype:"interrupt"}` that aborts the current turn without killing the process.
- **Transport:** WebSocket at `/ws` rides the same ngrok tunnel. The HTTP endpoints (`/session/new`, `/message`, `/info`, `/cancel`, `/settings`, `/qr`, `/activity`) are kept so nothing breaks and so `/activity` can still watch the conversation.
- **Reconnect safety:** if the phone drops off mid-run the server's persistent process finishes anyway; the reply is stashed as `pending_response` in `session.json` and delivered as a `turn_done` on the next WebSocket connect. Session IDs from the Claude CLI persist across restarts via `session.json` (server) and `UserDefaults` (iOS).

---

## iOS App (`Sources/`)

### Entry & lifecycle

| File | Key symbol | Purpose |
|---|---|---|
| `ClaudeCodeRemoteApp.swift` | `ClaudeCodeRemoteApp` | `@main` entry, attaches `AppDelegate` |
| `AppDelegate.swift` | `AppDelegate` | APNs registration, background fetch handler, routes notification taps to `AppState` via `NotificationCenter` |

### State machine

| File | Key symbol | Purpose |
|---|---|---|
| `AppState.swift` | `AppState` (`@MainActor ObservableObject`) | Central coordinator; owns `VoiceManager`, `RealtimeClient`, `APIService`, `SessionManager`; runs the duplex event loop |
| `AppState.swift` | `VoiceState` (enum) | Headline states: `idle` `connecting` `conversing` `error(String)` — the concurrent sub-states `isSpeaking / isListening / isWorking / isMuted` are published separately and can all be true at once during `.conversing` |
| `RealtimeClient.swift` | `RealtimeClient` (`@MainActor`) | `URLSessionWebSocketTask` wrapper — maps `serverURL` https→wss, speaks the v1 JSON protocol, pings every 20 s, auto-reconnects with backoff |
| `RealtimeClient.swift` | `ServerEvent` (enum) | `connected(reconnect:)` `disconnected` `session(id:)` `assistantDelta(String)` `toolActivity(String)` `turnDone(String)` `status(working:)` `serverError(String)` |

**`AppState` method flow:**
- `onAppear()` → requests permissions → `greet()`
- `greet()` → speaks welcome → `listenForSessionChoice()`
- `listenForSessionChoice()` → branches to `startNewSession()` or `continueSession()`
- both branch to `listenAndSend()` — the core loop
- `listenAndSend()` → STT → HTTP → TTS → `waitingForInput`
- `handleTap()` — called on every screen tap; interrupts speech or re-enters `listenAndSend()`
- `handleIncomingResponse()` — also called from notification observer when app wakes from background

### Voice I/O

| File | Key symbol | Purpose |
|---|---|---|
| `VoiceManager.swift` | `VoiceManager` (`@MainActor`) | Full-duplex audio engine — mic and player node on one `AVAudioEngine` with voice-processing AEC. Continuous SFSpeech, streaming PCM TTS, sentence-chunked speech queue, barge-in |
| `VoiceManager.swift` | `PlaybackCoordinator` (private) | Per-sentence bridge from the `AVSpeechSynthesizer.write()` callback thread to the player node; fires `onFinished` once synthesis is complete AND every buffer has played |

**`VoiceManager` public API:**
- `requestPermissions() async -> Bool` — mic + speech recognition
- `startDuplex() throws` — activates `.playAndRecord/.voiceChat`, enables `setVoiceProcessingEnabled(true)`, starts the engine and the first recognition cycle
- `stopDuplex()` — tears everything down and releases the audio session
- `setMuted(_ muted: Bool)` — stops feeding the recognizer without stopping the engine (tap-to-pause)
- `enqueueSpeech(_ delta: String)` — feed streaming text; complete sentences are spoken as they form
- `finishSpeech()` — turn's over, speak the remainder
- `flushSpeech()` — silence the player node immediately and drop everything queued (used by barge-in)
- `speakAndWait(_ text: String) async` — synthesize + play a full utterance and await completion
- `onUtterance: (String) -> Void` — a finished user utterance after silence endpointing
- `onBargeIn: () -> Void` — user started talking over TTS; the speech queue was just flushed

**Sentence chunking:** deltas accumulate; `. `, `! `, `? ` or newline flushes a sentence; long clauses (>250 chars) flush without punctuation; markdown code fences (```…```) are announced as "code block omitted" instead of being read.

**Continuous STT:** each `SFSpeechAudioBufferRecognitionRequest` runs until either a final result, a 1.8 s silence timer, or the 50 s cycle-restart timer (below Apple's ~60 s task cap). A fresh cycle starts immediately after — the mic tap keeps flowing to whatever request is current.

**Barge-in:** while `isSpeaking` is true, the first partial result with ≥ 2 words or ≥ 4 letters that is not itself a substring of the last ~400 chars of spoken text triggers `flushSpeech()` and fires `onBargeIn`. The utterance is then delivered normally when silence endpointing completes.

**Audio session:** `.playAndRecord`, mode `.voiceChat`, options `[.defaultToSpeaker, .allowBluetoothA2DP]` — activated once at `startDuplex()` and kept live. `AVAudioSession.interruptionNotification` handles phone calls / Siri and re-arms the graph on `.ended`.

### Networking

The realtime path is `RealtimeClient.swift` over `/ws`. `APIService.swift` is
kept for Settings (`/settings`), the legacy HTTP fallback endpoints, and the
server-side interrupt (`POST /session/cancel`) that the shake gesture calls.

| File | Key symbol | Purpose |
|---|---|---|
| `APIService.swift` | `APIService` | HTTP client — settings, cancel, and legacy session endpoints; reads `serverURL` from `UserDefaults` on every call |
| `APIService.swift` | `APIError` | `.serverNotConfigured` `.serverUnreachable` `.timeout` `.serverError(String)` |

**HTTP endpoints called (legacy / control-plane):**
- `GET/POST /settings` — server-side working directory
- `POST /session/cancel` — kill any active subprocess (belt-and-braces on hard reset)

### Persistence & notifications

| File | Key symbol | Purpose |
|---|---|---|
| `SessionManager.swift` | `SessionManager` | Thin wrapper around `UserDefaults`; stores `lastClaudeSessionId` |
| `NotificationManager.swift` | `NotificationManager` (singleton) | Requests notification permission, registers APNs, exposes `showLocalNotification()` |

### UI

| File | Key symbol | Purpose |
|---|---|---|
| `ContentView.swift` | `ContentView` | Full-screen SwiftUI view. Colors and ring animation composite the current sub-states (speaking, listening, working, muted) into one indicator |
| `SettingsView.swift` | `SettingsView` | Server URL, working directory, session clear — for sighted caregiver setup only |

**Gestures:**
- **tap** → mute/unmute (from `.idle`/`.error` → start conversation)
- **long press 0.8 s** → interrupt current work (only when `isWorking`)
- **long press 1.5 s** → open Settings
- **shake** → hard reset (stop everything, drop session, reconnect fresh)

**State → color:** black=idle, indigo=connecting, green=listening (default), blue=Claude speaking, orange=Claude working, gray=muted, red=error.

---

## Bot Server (`bot/`)

| File | Key symbol | Purpose |
|---|---|---|
| `server.py` | FastAPI `app` | Main entry point. Owns `_duplex_session` (one `ClaudeSession`), exposes `/ws`, keeps HTTP `/session/*` and `/settings` and the `/activity` SSE + browser page |
| `server.py` | `ws_endpoint(websocket)` | v1 JSON protocol — receives `start`/`user_text`/`interrupt`/`ping`, fans server events (`session`/`assistant_delta`/`tool_activity`/`turn_done`/`status`/`error`) to every connected client |
| `server.py` | `_duplex_event(evt)` | Reader-thread event hook: persists session id and last response, stashes `pending_response` when nobody is connected, drives `_broadcast` for the /activity page |
| `claude_session.py` | `ClaudeSession` | Persistent Claude process. `start()` spawns `claude --print --input-format stream-json --output-format stream-json --include-partial-messages --verbose --dangerously-skip-permissions --mcp-config …` (optionally `--resume`); `send_user()` writes stream-json user messages to stdin (works mid-turn); `interrupt()` writes a `control_request:{subtype:"interrupt"}`; a background thread parses stdout into normalized events |
| `claude_session.py` | `_tool_summary(name, input)` | Turns `tool_use` blocks into short spoken summaries — "Editing AppState.swift", "Running command: git status", etc. |
| `claude_runner.py` | `start_claude`/`collect_claude`/`kill_claude` | Kept for the legacy per-turn HTTP endpoints (unused by the duplex loop) |
| `telegram_notifier.py` | `send_message`/`poll_and_register` | Unchanged Telegram push layer |

**Session file schema (`session.json`):**
```json
{
  "session_id": "claude-session-uuid",
  "last_response": "...",
  "pending_response": null
}
```
`pending_response` is set when a `turn_done` arrives and no WS client is connected; cleared next time a client sends `start` (delivered as a `turn_done` event) or `GET /session/info` is called.

**WebSocket protocol (v1):**

Client → server (JSON per frame):
- `{"type":"start","resume":bool}` — attach/create the persistent session
- `{"type":"user_text","text":"…"}` — user utterance (steers mid-turn if working, starts a new turn if idle)
- `{"type":"interrupt"}` — abort the current turn
- `{"type":"ping"}`

Server → client (JSON per frame; every message carries `"v":1`):
- `{"type":"session","session_id":"…"}`
- `{"type":"assistant_delta","text":"…"}`
- `{"type":"tool_activity","text":"Editing X"}`
- `{"type":"turn_done","text":"…","session_id":"…"}`
- `{"type":"status","state":"working"|"idle"}`
- `{"type":"error","message":"…"}`
- `{"type":"pong"}`

**Environment variables (bot/.env):**
- `TELEGRAM_BOT_TOKEN` — from @BotFather (optional; Telegram push won't work without it)
- `TELEGRAM_USER_CHAT_ID` — manual override if auto-registration fails
- `PORT` — default 8080

---

## Setup summary

```bash
# Server (Mac)
cd bot && bash setup.sh          # one-time: venv, deps, checks
source .venv/bin/activate
python server.py                 # keep running
ngrok http 8080                  # in another terminal; copy https:// URL

# iOS
xcodegen generate                # only needed after adding/renaming Swift files
open ClaudeCodeRemote.xcodeproj  # sign with Apple ID, run on device
# Long press main screen → Settings → paste ngrok URL → Save
```

**To regenerate the Xcode project after adding files:**
```bash
xcodegen generate
```
All source files live flat in `Sources/` — XcodeGen picks them up automatically.
