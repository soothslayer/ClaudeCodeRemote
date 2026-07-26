# Claude Code Remote — Project Guide

Voice-only iOS app that lets a blind user **call Claude Code like a phone contact**. The app is a VoIP client (CallKit) whose only contact is Claude Code running on a remote Mac; a Python bot server bridges the call to a persistent Claude Code CLI process over a WebSocket.

---

## Architecture

```
iPhone (iOS app)
  │  user taps Call (or just opens the app)
  ▼
CallManager (CallKit)
  │  CXStartCallAction → system activates AVAudioSession
  ▼
VoiceManager (full-duplex AVAudioEngine)
  │  ringback tone plays while…
  ▼
RealtimeClient ──── WebSocket /ws ────► FastAPI server (bot/server.py)  [Mac]
  │                                          │
  │  user_text / interrupt        ▲          ▼
  │  assistant_delta / tool_activity   claude_session.py
  │  turn_done / status                ONE persistent process:
  │                                    claude --print --input-format stream-json
  │                                           --output-format stream-json
  │                                           [--resume <id>]
  ▼                                          │
VoiceManager speaks deltas as they stream    └── computer_use_mcp.py sidecar
(mic stays live — barge-in interrupts)           (mouse/keyboard/screenshot MCP)
```

**Key design decisions:**
- **Every conversation is a real CallKit call** — outgoing `CXStartCallAction` to the generic handle "Claude Code". This buys the native lock-screen call UI (fully VoiceOver accessible), the green in-call pill, call-grade background audio priority, and AirPods/Bluetooth mute controls for free. If CallKit refuses the call, the app silently falls back to plain in-app audio.
- **Full-duplex audio** — the mic stays live while TTS plays (echo-cancelled via voice processing). The user can talk over Claude at any time; barge-in flushes the speech queue.
- **Phone-call mute semantics** — mute silences the *microphone only*; Claude keeps talking, exactly like muting yourself on a real call.
- **Hanging up does not kill server-side work** — the persistent Claude process keeps running; calling back resumes the session (`--resume <id>`, persisted in `UserDefaults` on iOS and `session.json` on the server).
- **A ringback tone** (440+480 Hz, US cadence, generated in code) plays while the WebSocket connects — eyes-free "it's dialing" feedback.
- **Transport is a WebSocket** (`/ws`, JSON protocol v1) with auto-reconnect + backoff; responses that arrive while disconnected are stashed as `pending_response` and delivered on reconnect. The old HTTP endpoints remain for settings, cancel, and background recovery.
- The server is exposed via **ngrok**; setup is a `clauderemote://setup?url=…` magic link or QR code — no manual typing.
- No push notifications — Telegram integration was removed entirely.

---

## iOS App (`Sources/`)

### Call & state machine

| File | Key symbol | Purpose |
|---|---|---|
| `ClaudeCodeRemoteApp.swift` | `ClaudeCodeRemoteApp` | `@main` entry, attaches minimal `AppDelegate` |
| `AppState.swift` | `AppState` (`@MainActor ObservableObject`) | Central coordinator; owns `VoiceManager`, `CallManager`, `RealtimeClient`, `APIService`, `SessionManager` |
| `AppState.swift` | `VoiceState` (enum) | `idle` → `dialing` → `onCall` (+ `error`); sub-states `isSpeaking`/`isListening`/`isWorking`/`isMuted` overlap during `onCall` |
| `CallManager.swift` | `CallManager` | CallKit wrapper (`CXProvider` + `CXCallController`). Mute is single-sourced through `CXSetMutedCallAction` so app UI, lock screen, and AirPods stay in sync |

**Call flow (`AppState`):**
- `onAppear()` → permissions → auto-`placeCall(resume:)` (opening the app IS the intent to call)
- `placeCall()` → `CallManager.startCall()` → CallKit activates the audio session → `callAudioActivated()` → start duplex engine → ringback → `RealtimeClient.connect()` → on success `reportConnected()`, greeting, `startSession(resume:)`
- No answer → `failCall()` speaks the reason, reports the call failed
- `hangUp()` → `CXEndCallAction` → `callDidEnd()` is the single teardown point (also fires for lock-screen End)
- `toggleMute()` routes through CallKit; the actual mic change lands in `applyMute()` via the delegate

**Gestures (ContentView):** tap background/avatar = mute (or call from idle) · long-press 0.8 s = interrupt Claude · long-press 1.5 s = Settings · shake = hard reset (hang up, drop session, redial fresh). Saying "stop" / "cancel" while Claude works also interrupts.

### Voice I/O

| File | Key symbol | Purpose |
|---|---|---|
| `VoiceManager.swift` | `VoiceManager` (`@MainActor`) | Full-duplex engine: one `AVAudioEngine` with voice-processing (AEC) on the input node; TTS rendered offline via `AVSpeechSynthesizer.write()` onto an `AVAudioPlayerNode`; `SFSpeechRecognizer` runs in ~50 s cycles with a 1.8 s silence endpoint |

**`VoiceManager` essentials:**
- `callKitOwnsSession` — when true, CallKit activates/deactivates the `AVAudioSession` (we only set the category in `configureCallAudioSession()`), and mute becomes mic-only
- `startDuplex()` / `stopDuplex()` — build/tear down the audio graph; `resumeEngineIfNeeded()` recovers after CallKit re-activation (held call, Siri)
- `enqueueSpeech(delta)` — streaming TTS, chunked into sentences; markdown sanitized; code blocks skipped ("Code block omitted")
- `startRingback()` / `stopRingback()` — generated ringback loop on a dedicated player node
- Barge-in: a real partial STT result while TTS plays flushes speech and steers Claude; echo of our own TTS is filtered
- Voice picker: Settings lists installed English voices (premium → enhanced), persisted under `selectedVoiceId`

### Networking

| File | Key symbol | Purpose |
|---|---|---|
| `RealtimeClient.swift` | `RealtimeClient` | WebSocket to `/ws` (http→ws, https→wss). Auto-reconnects with backoff; re-sends `start(resume:true)` after a drop so pending responses flow in; 20 s keepalive pings |
| `RealtimeClient.swift` | `ServerEvent` (enum) | `connected` `disconnected` `session` `assistantDelta` `toolActivity` `turnDone` `status` `serverError` |
| `APIService.swift` | `APIService` | HTTP for everything non-realtime: `/session/cancel`, `/settings` (get/post), `/settings/browse` (folder picker), plus legacy `/session/new`·`/session/message`·`/session/info` |

**WebSocket protocol v1** (JSON, snake_case):
- up: `start {resume}` · `user_text {text}` · `interrupt` · `ping`
- down: `session {session_id}` · `assistant_delta {text}` · `tool_activity {text}` · `turn_done {text}` · `status {state: working|idle}` · `error {message}` · `pong`

### Persistence, setup & support

| File | Key symbol | Purpose |
|---|---|---|
| `SessionManager.swift` | `SessionManager` | `UserDefaults` wrapper for `lastClaudeSessionId` |
| `SettingsView.swift` | `SettingsView` | Server URL (paste / QR scan), working-directory picker (browses the server's home dir), voice picker, in-app log viewer. For sighted-caregiver setup |
| `QRScannerView.swift` | `QRScannerView` | VisionKit QR scanner for the setup link |
| `ShakeDetector.swift` | `onShake` modifier | Shake-to-reset via responder chain |
| `AppLogger.swift` | `AppLogger.shared` | os.Logger + last 300 entries in memory for the Settings log viewer |

### UI

| File | Key symbol | Purpose |
|---|---|---|
| `ContentView.swift` | `ContentView` | Phone-call UI: contact header ("Claude Code" + live call timer), state avatar (color/icon per sub-state), call controls — green Call button when idle; Mute / Audio-route (`AVRoutePickerView`) / End on a call. All controls VoiceOver-labeled |

**Avatar colors:** green=listening/ready, blue=Claude talking, orange=working, gray=muted, indigo=dialing, red=error.

---

## Bot Server (`bot/`)

| File | Key symbol | Purpose |
|---|---|---|
| `server.py` | FastAPI `app` | `WS /ws` (duplex), `POST /session/new·message·cancel`, `GET /session/info`, `GET/POST /settings`, `GET /settings/browse`, `GET /activity` (+ `/activity/stream` SSE, `POST /activity/send`), `GET /qr`, `GET /ngrok-url`, `GET /health` |
| `claude_session.py` | `ClaudeSession` | ONE persistent `claude --print --input-format stream-json --output-format stream-json [--resume]` process. Mid-turn `user` messages steer the run; `control_request {interrupt}` aborts a turn without killing the process. Normalizes stdout into the WS event types; auto-restarts fresh if `--resume` fails |
| `claude_runner.py` | `start_claude` / `collect_claude` / `kill_claude` | Legacy one-shot subprocess per prompt (`--output-format json`) — still used by the HTTP endpoints; survives client disconnect by stashing the result as `pending_response` |
| `computer_use_mcp.py` | MCP stdio server | Gives Claude computer-use on the Mac: screenshot, click, type, key chords, scroll (via `cliclick` + AppleScript). Attached to every Claude process via inline `--mcp-config` |
| `menu_bar.py` | `ClaudeRemoteApp` (rumps) | Menu-bar app: auto-starts uvicorn + ngrok at login (LaunchAgent, KeepAlive), shows status, Copy Magic Link / Open QR Page / Open Activity Window / Restart |
| `setup.sh` | — | One-time: venv, deps, `cliclick`, LaunchAgent install |

Claude runs with `--dangerously-skip-permissions` in a configurable working directory (`config.json`, default `~/git/buck`); changing `work_dir` from iOS Settings tears down the duplex session and announces the fresh start on the phone.

**State files (`bot/`):**
- `session.json` — `{session_id, last_response, pending_response}`; `pending_response` is read-once, delivered on the next `/ws` `start` or `GET /session/info`
- `config.json` — `{work_dir}`
- `.env` — `PORT` (default 8080)

**Operator surfaces:** `http://localhost:8080/activity` is a live browser view of every Claude stdout line (SSE) with a text box to type into the same session; `/qr` renders the magic-link QR for setup.

---

## Setup summary

```bash
# Server (Mac) — option A: menu bar app (auto-start at login)
cd bot && bash setup.sh          # one-time: venv, deps, cliclick, LaunchAgent
# then use the ☁ menu bar icon → Copy Magic Link

# Server — option B: manual
source .venv/bin/activate
python server.py                 # or: python menu_bar.py
ngrok http 8080                  # separate terminal

# iOS
xcodegen generate                # after adding/renaming Swift files
open ClaudeCodeRemote.xcodeproj  # sign with Apple ID, run on device
# Setup: text the magic link (clauderemote://setup?url=…) to the phone,
# or long-press → Settings → Scan QR Code (QR page: http://localhost:8080/qr)
```

All source files live flat in `Sources/` — XcodeGen (`brew install xcodegen`) picks them up automatically from `project.yml`.

If `xcodebuild` fails from the CLI with a CoreSimulator version mismatch after an Xcode update, open Xcode once (or reboot) to let it finish installing; building to a device from the Xcode GUI is unaffected. If `xcode-select` points at CommandLineTools, prefix CLI builds with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
