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
| `ContentView.swift` | `ContentView` | Phone-call UI: contact header ("Claude Code" + live call timer), state avatar (color/icon per sub-state), call controls — green Call button when idle; Mute / Audio-route (`AVRoutePickerView`) / End on a call. All controls VoiceOver-labeled. `#if DEBUG` adds a "Send test message" button under the call controls that calls `AppState.sendSimulatedUtterance()` — it injects canned text through the real speech path so the device → server → response round trip can be checked on the Simulator, which has no microphone |

**Avatar colors:** green=listening/ready, blue=Claude talking, orange=working, gray=muted, indigo=dialing, red=error.

---

## Bot Server (`bot/`)

| File | Key symbol | Purpose |
|---|---|---|
| `server.py` | FastAPI `app` | `WS /ws` (duplex), `POST /session/new·message·cancel`, `GET /session/info`, `GET/POST /settings`, `GET /settings/browse`, `GET /activity` (+ `/activity/stream` SSE, `POST /activity/send`), `GET /qr`, `GET /ngrok-url`, `GET /health` |
| `claude_session.py` | `ClaudeSession` | ONE persistent `claude --print --input-format stream-json --output-format stream-json [--resume]` process. Mid-turn `user` messages steer the run; `control_request {interrupt}` aborts a turn without killing the process. Normalizes stdout into the WS event types; auto-restarts fresh if `--resume` fails |
| `claude_runner.py` | `start_claude` / `collect_claude` / `kill_claude` | Legacy one-shot subprocess per prompt (`--output-format json`) — still used by the HTTP endpoints; survives client disconnect by stashing the result as `pending_response` |
| `computer_use_mcp.py` | MCP stdio server | Gives Claude computer-use on the Mac: screenshot, click, type, key chords, scroll (via `cliclick` + AppleScript). Attached to every Claude process via inline `--mcp-config` |
| `menu_bar.py` | `ClaudeRemoteApp` (rumps) | Menu-bar app: runs uvicorn on a daemon thread, uses `NgrokSupervisor` to launch/restart ngrok (with configured static domain), file logs to `~/Library/Logs/ClaudeCodeRemote/`, menu items include Copy Magic Link, Configure ngrok (authtoken + static domain), Reveal Logs, Restart, Quit |
| `ngrok_supervisor.py` | `NgrokSupervisor` | Threaded supervisor that launches ngrok, restarts on death (exponential backoff to 60 s), polls `http://127.0.0.1:4040/api/tunnels` for the public URL, and re-launches with a new `--domain` when the configured static domain changes |
| `voice_prompt.py` | `VOICE_SYSTEM_PROMPT` | Voice-interface framing passed to every Claude process via `--append-system-prompt` (both `claude_session.py` and `claude_runner.py`). Tells the model its output is spoken aloud by TTS to a blind listener: no markdown, no code blocks, lead with the answer, keep it short, speak paths naturally. The iOS `VoiceManager` still sanitizes markdown as a backstop |
| `paths.py` | `config_dir`, `log_dir`, `ngrok_binary`, `claude_binary`, `mcp_sidecar`, `migrate_legacy_state` | Runtime location helper — resolves writable dirs (`~/Library/Application Support/ClaudeCodeRemote/`, `~/Library/Logs/ClaudeCodeRemote/`) and locates the ngrok binary (bundled in `Contents/Resources/bin/ngrok` when running from the .app, else PATH). `claude_binary()` finds the `claude` CLI — PATH first, then `~/.local/bin`, Homebrew, and npm/nvm/volta prefixes — because a py2app bundle and a LaunchAgent both inherit a bare PATH that lacks it. `mcp_sidecar()` resolves `computer_use_mcp.py` to a real file — the bundle ships an uncompiled copy in `Contents/Resources/` because `python3` cannot run a script from inside `python3xx.zip`. Migrates legacy `bot/config.json` / `bot/session.json` on first access |
| `setup_app.py` | `py2app` recipe | Builds `ClaudeCodeRemote.app` — `LSUIElement=True` (menu-bar only), bundles the server + MCP sidecar + rumps UI + a copy of the ngrok binary if one is on the build machine |
| `setup.sh` | — | One-time: venv, deps (incl. py2app), `cliclick`, builds `ClaudeCodeRemote.app` with py2app, copies to `/Applications/`, registers a LaunchAgent that runs `Contents/MacOS/ClaudeCodeRemote` |

Claude runs with `--dangerously-skip-permissions` in a configurable working directory (`config.json`, default `~/git/buck`); changing `work_dir` from iOS Settings tears down the duplex session and announces the fresh start on the phone.

**State files (`~/Library/Application Support/ClaudeCodeRemote/`):**
- `session.json` — `{session_id, last_response, pending_response}`; `pending_response` is read-once, delivered on the next `/ws` `start` or `GET /session/info`
- `config.json` — `{work_dir, ngrok_static_domain}`
- `.env` (in `bot/`) — `PORT` (default 8080)

Legacy `bot/config.json` and `bot/session.json` are auto-migrated on first launch (see `paths.migrate_legacy_state`). Logs go to `~/Library/Logs/ClaudeCodeRemote/`.

**Operator surfaces:** `http://localhost:8080/activity` is a live browser view of every Claude stdout line (SSE) with a text box to type into the same session; `/qr` renders the magic-link QR for setup.

---

## macOS Server App (`MacSources/`, `mac/`)

An Xcode target — `ClaudeCodeRemoteServer`, generated by the same `project.yml` as the iOS app — that ships the `bot/` server as a signed, notarizable Mac app. It is a thin Swift shell: it owns the menu bar and supervises `bot/serve_headless.py` as a child process. This supersedes the py2app path (`bot/setup_app.py`, `bot/setup.sh`), which remains for the source-tree deployment.

| File | Key symbol | Purpose |
|---|---|---|
| `MacSources/ClaudeCodeRemoteServerApp.swift` | `ClaudeCodeRemoteServerApp` | `@main` `MenuBarExtra` + two `Window` scenes (ngrok setup, log). Title is `☁` connecting / `☁✓` tunnel up / `☁!` error |
| `MacSources/ServerController.swift` | `ServerController` (`@MainActor ObservableObject`) | Spawns `python3 serve_headless.py`, parses its JSON-line protocol into `State` (`stopped`/`starting`/`waitingForTunnel`/`running(url:)`/`failed`), keeps a 500-line log ring. Starts in `init()`; tears the child down on `NSApplication.willTerminateNotification` |
| `MacSources/BundleLayout.swift` | `BundleLayout` | Resolves `Contents/Resources/{python,bot,bin/ngrok}` and splices the well-known `claude` install dirs into the child's `PATH` — a GUI app inherits a bare PATH from launchd |
| `MacSources/NgrokConfig.swift` | `NgrokConfig` | Reads/writes the same `config.json` the Python side uses, preserving keys it does not own. The authtoken goes to `ngrok config add-authtoken`, never into our config |
| `MacSources/LoginItem.swift` | `LoginItem` | Launch-at-login via `SMAppService.mainApp` — no hand-written LaunchAgent plist to keep in sync |
| `MacSources/MenuContent.swift` · `NgrokSettingsView.swift` · `ServerLogView.swift` | — | Menu (Copy Magic Link, QR, Activity, Configure ngrok, Show Log, Launch at Login, Restart, Quit), setup sheet, live log tail |
| `bot/serve_headless.py` | `main` | UI-less twin of `menu_bar.py`: uvicorn + `NgrokSupervisor`, no rumps. Emits one JSON object per line on stdout (`starting`/`server_ready`/`ngrok_url`/`log`/`fatal`). A watchdog thread polls `os.getppid()` and SIGTERMs itself when reparented, so a crashed or Force-Quit host cannot leak uvicorn and ngrok onto the port |
| `bot/requirements-server.txt` | — | Runtime deps only — excludes `rumps` (Swift owns the menu bar) and `py2app` |
| `mac/build_python_runtime.sh` | — | Xcode post-build phase. Stages a relocatable CPython (python-build-standalone, via `uv`) plus deps into `Contents/Resources/python`, the server sources into `Resources/bot`, and `ngrok` into `Resources/bin`. Caches on a version+requirements stamp. Re-signs every staged Mach-O — files a script phase copies are invisible to Xcode's signing, and notarization rejects unsigned nested code |
| `mac/release.sh` | — | archive → Developer ID export → `notarytool submit --wait` → staple → DMG |

**Distribution is Developer ID + notarization, not TestFlight.** macOS TestFlight goes through App Store Connect, which requires a Mac App Store profile, which requires the App Sandbox. The server execs the `claude` CLI from outside the container, lets Claude edit arbitrary working directories under `--dangerously-skip-permissions`, and posts synthetic input events via `computer_use_mcp.py` — none of which survive sandboxing. Testers get a notarized DMG instead. The iOS app is unaffected and ships on TestFlight normally.

**Entitlements** (`MacSources/ClaudeCodeRemoteServer.entitlements`, hardened runtime on, sandbox off): `disable-library-validation` (embedded CPython loads C extensions we did not sign), `allow-dyld-environment-variables`, `automation.apple-events` (the computer-use MCP drives other apps).

`paths.py` needs no changes under this layout — `sys.executable` lands at `Contents/Resources/python/bin/python3`, so `running_in_bundle()`, `ngrok_binary()`, and `mcp_sidecar()` all resolve against `Contents/Resources` exactly as they did under py2app.

**Testing knobs:** `CLAUDE_REMOTE_DISABLE_NGROK=1` suppresses the tunnel (a second ngrok agent evicts the first on a free account); `defaults write com.claudecoderemote.server serverPort <n>` moves the app off 8080 so it can run beside an existing instance.

```bash
# Build and run the Mac server app
xcodegen generate
xcodebuild -project ClaudeCodeRemote.xcodeproj -scheme ClaudeCodeRemoteServer -configuration Release build

# Ship it to testers (see the header of mac/release.sh for the one-time
# Developer ID certificate and notarytool credential setup)
bash mac/release.sh
```

---

## Setup summary

```bash
# Server (Mac) — option A: standalone .app (recommended, auto-starts at login)
cd bot && bash setup.sh          # builds ClaudeCodeRemote.app, installs to /Applications, LaunchAgent
# then use the ☁ menu bar icon → Configure ngrok… (paste authtoken + free static domain)
#                              → Copy Magic Link

# Server — option B: from source (dev loop)
source .venv/bin/activate
python menu_bar.py               # runs uvicorn + supervised ngrok in-process
# (no separate `ngrok http 8080` needed — the supervisor handles it)

# iOS
xcodegen generate                # after adding/renaming Swift files
open ClaudeCodeRemote.xcodeproj  # sign with Apple ID, run on device
# Setup: text the magic link (clauderemote://setup?url=…) to the phone,
# or long-press → Settings → Scan QR Code (QR page: http://localhost:8080/qr)
```

All source files live flat in `Sources/` — XcodeGen (`brew install xcodegen`) picks them up automatically from `project.yml`.

If `xcodebuild` fails from the CLI with a CoreSimulator version mismatch after an Xcode update, open Xcode once (or reboot) to let it finish installing; building to a device from the Xcode GUI is unaffected. If `xcode-select` points at CommandLineTools, prefix CLI builds with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
