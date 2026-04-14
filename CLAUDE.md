# Claude Code Remote — Project Guide

Voice-only iOS app that lets a blind user speak to Claude Code running on a remote computer, using a Python bot server as the bridge and Telegram for push notifications.

---

## Architecture

```
iPhone (iOS app)
  │  speaks prompt
  ▼
VoiceManager (STT)
  │  text string
  ▼
APIService ──── HTTP POST ────► FastAPI server (bot/server.py)  [runs on Mac]
                                      │
                                      ▼
                               claude_runner.py
                               runs: claude --print <prompt> --output-format json
                                      │
                                      ▼
                               FastAPI returns JSON response
                                      │
               ◄──── HTTP response ───┘
                                      │ also
                                      ▼
                               telegram_notifier.py
                               sends Telegram message to user
                               (push notification if app is backgrounded)
  │
  ▼
VoiceManager (TTS) reads response aloud
```

**Key design decisions:**
- HTTP is synchronous request/response with a **5-minute timeout** (Claude Code can be slow)
- No async job queue — the iOS app holds the connection open while Claude runs
- Telegram is notification-only, not the primary transport; the iOS↔server link is plain HTTPS
- The server is exposed to the internet via **ngrok** (no port forwarding needed)
- Session IDs from the Claude CLI (`--resume <id>`) are persisted in `UserDefaults` on iOS and in `session.json` on the server, allowing multi-turn conversations across app restarts

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
| `AppState.swift` | `AppState` (`@MainActor ObservableObject`) | Central coordinator; owns `VoiceManager`, `APIService`, `SessionManager`, `NotificationManager`; drives the voice state machine |
| `AppState.swift` | `VoiceState` (enum) | States: `idle` `speaking` `listeningForChoice` `listeningForPrompt` `processing` `waitingForInput` `error(String)` |

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
| `VoiceManager.swift` | `VoiceManager` (`@MainActor`) | All TTS and STT; wraps AVSpeechSynthesizer + SFSpeechRecognizer in `async/await` |

**`VoiceManager` public API:**
- `requestPermissions() async -> Bool` — requests microphone + speech recognition
- `speak(_ text: String) async` — blocks until utterance finishes (or is stopped)
- `stopSpeaking()` — interrupts current utterance; resumes the `speak` continuation via delegate
- `listen() async -> String?` — starts audio capture; returns transcription or `nil`; uses 1.8s silence timer to auto-stop; hard 30s timeout
- `stopListening()` — calls `recognitionRequest?.endAudio()` to end capture early

**Silence detection:** a `DispatchWorkItem` is rescheduled on every partial STT result; fires after 1.8s of quiet and calls `endAudio()`.

**Audio session switching:** `.playback/.spokenAudio` for TTS, `.record/.measurement` for STT. The session is deactivated after each listen to hand audio back to other apps.

### Networking

| File | Key symbol | Purpose |
|---|---|---|
| `APIService.swift` | `APIService` | HTTP client; reads `serverURL` from `UserDefaults` on every call (so Settings changes are immediate); 300s request timeout |
| `APIService.swift` | `APIError` (enum) | `.serverNotConfigured` `.serverUnreachable` `.timeout` `.serverError(String)` |
| `APIService.swift` | `NewSessionResult` | `{ sessionId, response }` |
| `APIService.swift` | `MessageResult` | `{ sessionId, response }` |
| `APIService.swift` | `SessionInfoResult` | `{ hasSession, sessionId?, pendingResponse? }` |

**Endpoints called:**
- `POST /session/new` — new Claude session
- `POST /session/message` — follow-up in existing session
- `GET /session/info` — background-fetch polling; clears `pendingResponse` after reading

### Persistence & notifications

| File | Key symbol | Purpose |
|---|---|---|
| `SessionManager.swift` | `SessionManager` | Thin wrapper around `UserDefaults`; stores `lastClaudeSessionId` |
| `NotificationManager.swift` | `NotificationManager` (singleton) | Requests notification permission, registers APNs, exposes `showLocalNotification()` |

### UI

| File | Key symbol | Purpose |
|---|---|---|
| `ContentView.swift` | `ContentView` | Full-screen SwiftUI view; tap → `appState.handleTap()`; long press (1.5s) → `SettingsView` sheet; animated circle changes color/icon per `VoiceState`; VoiceOver-accessible as a single button |
| `SettingsView.swift` | `SettingsView` | Form with server URL text field + "Clear Session" button; uses `@AppStorage("serverURL")`; intended for sighted caregiver setup only |

**State → color mapping:** blue=speaking, green=listening, orange=processing, purple=waitingForInput, red=error.

---

## Bot Server (`bot/`)

| File | Key symbol | Purpose |
|---|---|---|
| `server.py` | FastAPI `app` | Main entry point; `POST /session/new`, `POST /session/message`, `GET /session/info`, `GET /health`; persists session to `session.json`; calls `run_claude` in a thread pool (`asyncio.to_thread`) |
| `claude_runner.py` | `run_claude(prompt, session_id?) -> (str, str)` | Runs `claude --print <prompt> --output-format json [--resume <id>]`; parses newline-delimited JSON stream for the `"type":"result"` object; 300s subprocess timeout |
| `claude_runner.py` | `_parse_output(raw, fallback_id)` | Iterates JSON lines, extracts `result` and `session_id`; falls back to raw stdout if no JSON found |
| `telegram_notifier.py` | `send_message(text, chat_id?)` | Async; calls Telegram `sendMessage` API; truncates to 4000 chars; non-fatal on failure |
| `telegram_notifier.py` | `poll_and_register()` | Long-polls Telegram `getUpdates`; auto-saves user `chat_id` to `chat_id.txt` when they send any message to the bot; sends a confirmation reply |
| `telegram_notifier.py` | `get_chat_id() / save_chat_id()` | Read/write `chat_id.txt`; falls back to `TELEGRAM_USER_CHAT_ID` env var |

**Session file schema (`session.json`):**
```json
{
  "session_id": "claude-session-uuid",
  "last_response": "...",
  "pending_response": null
}
```
`pending_response` is set when a response arrives and the iOS app is believed to be backgrounded; cleared by `GET /session/info`.

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
