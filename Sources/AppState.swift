import Foundation
import Combine

// MARK: - Voice State (headline UI state — the coloured circle)

enum VoiceState: Equatable {
    case idle           // pre-first-tap or muted between conversations
    case connecting     // opening WebSocket to server
    case conversing     // duplex live — sub-states expressed in isSpeaking/isListening/isWorking
    case error(String)
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    // Headline UI state
    @Published private(set) var voiceState: VoiceState = .idle
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isRequestingPermissions = false

    // Sub-states (all valid simultaneously during .conversing)
    @Published private(set) var isSpeaking = false          // TTS audible
    @Published private(set) var isListening = false         // mic hot + hearing user
    @Published private(set) var isWorking = false           // Claude Code is thinking
    @Published private(set) var isMuted = false

    // Collaborators
    let voiceManager: VoiceManager
    let realtimeClient: RealtimeClient
    let apiService: APIService
    let sessionManager: SessionManager

    // Once true, tapping in .conversing toggles mute rather than re-issuing
    // the greeting. Reset on shake/hard reset.
    private var duplexEverStarted = false
    private var lastToolActivityAt: Date = .distantPast
    private var subscriptions = Set<AnyCancellable>()

    init() {
        voiceManager = VoiceManager()
        realtimeClient = RealtimeClient()
        apiService = APIService()
        sessionManager = SessionManager()

        // Mirror VoiceManager's published sub-states so ContentView can react.
        voiceManager.$isSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isSpeaking = $0 }
            .store(in: &subscriptions)
        voiceManager.$isHearingUser
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isListening = $0 }
            .store(in: &subscriptions)
        voiceManager.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isMuted = $0 }
            .store(in: &subscriptions)

        voiceManager.onUtterance = { [weak self] text in
            self?.handleUserUtterance(text)
        }
        voiceManager.onBargeIn = { [weak self] in
            self?.handleBargeIn()
        }

        realtimeClient.onEvent = { [weak self] event in
            self?.handleServerEvent(event)
        }
    }

    // MARK: - Entry

    func onAppear() async {
        let log = AppLogger.shared
        log.log("onAppear start", tag: "INIT")

        isRequestingPermissions = true
        let granted = await voiceManager.requestPermissions()
        isRequestingPermissions = false

        guard granted else {
            let msg = "Permissions required. Open Settings and allow microphone and speech recognition access."
            await voiceManager.speakAndWait(msg)
            await transition(to: .error(msg))
            return
        }

        // Server URL not set? Wait for the setup link — same as before.
        let hasURL = !(UserDefaults.standard.string(forKey: "serverURL")?.isEmpty ?? true)
        guard hasURL else {
            let msg = "Please set the server URL. Long press to open Settings, or tap a setup link."
            await voiceManager.speakAndWait(msg)
            await transition(to: .idle)
            return
        }

        await startConversation(resume: sessionManager.hasSession)
    }

    // MARK: - Magic link (unchanged behaviour)

    func handleSetupLink(_ url: URL) async {
        guard url.scheme?.lowercased() == "clauderemote",
              url.host?.lowercased() == "setup",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let serverURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              !serverURL.isEmpty else { return }

        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        AppLogger.shared.log("Server URL set via magic link: \(serverURL)", tag: "LINK")

        if !duplexEverStarted {
            await voiceManager.speakAndWait("Server connected. Tap anywhere to start.")
        }
    }

    // MARK: - Conversation lifecycle

    private func startConversation(resume: Bool) async {
        duplexEverStarted = true
        await transition(to: .connecting)

        // Start the duplex audio engine BEFORE speaking the greeting — that
        // way the greeting flows through the same pipeline the rest of the
        // conversation uses (single audio session state, mic already live for
        // barge-in). Splitting greeting → then engine start caused the audio
        // session to reconfigure between them, which on some Bluetooth routes
        // left the mic silent.
        do {
            try voiceManager.startDuplex()
        } catch {
            let msg = "Could not start audio: \(error.localizedDescription)"
            await transition(to: .error(msg))
            await voiceManager.speakAndWait(msg)
            return
        }
        await transition(to: .conversing)

        await voiceManager.speakAndWait(
            resume
                ? "Reconnecting to your session."
                : "Starting a new session. Say hello when you're ready."
        )

        let connected = await realtimeClient.connect()
        if !connected {
            await transition(to: .error("Could not reach the server. Retrying."))
            await transition(to: .conversing)
        }
        realtimeClient.startSession(resume: resume)
    }

    // MARK: - Server events

    private func handleServerEvent(_ event: ServerEvent) {
        switch event {
        case .connected(let reconnect):
            if reconnect {
                voiceManager.enqueueSpeech("Reconnected. ")
            }
            if voiceState != .conversing {
                Task { await transition(to: .conversing) }
            }

        case .disconnected:
            voiceManager.enqueueSpeech("Connection dropped. Reconnecting. ")

        case .session(let id):
            sessionManager.saveSession(id: id)

        case .assistantDelta(let text):
            voiceManager.enqueueSpeech(text)

        case .toolActivity(let text):
            // Speak at most one tool summary every 30 s so we don't chatter.
            let now = Date()
            if now.timeIntervalSince(lastToolActivityAt) >= 30 {
                lastToolActivityAt = now
                voiceManager.enqueueSpeech(text + ". ")
            }

        case .turnDone(let final):
            // Server's `result` — flush any remainder the deltas didn't cover.
            let sanitized = VoiceManager.sanitizeForSpeech(final)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sanitized.isEmpty {
                voiceManager.finishSpeech()
            }
            isWorking = false
            statusMessage = statusFor(voiceState)

        case .status(let working):
            isWorking = working
            if !working { lastToolActivityAt = .distantPast }
            statusMessage = statusFor(voiceState)

        case .serverError(let message):
            AppLogger.shared.log("server error: \(message)", tag: "WS")
            voiceManager.enqueueSpeech("Server error: \(message). ")
        }
    }

    // MARK: - User speech

    private func handleUserUtterance(_ text: String) {
        AppLogger.shared.log("utterance: \"\(text)\"", tag: "STT")

        // Wake-word interrupt: "stop" / "cancel" (± "claude") aborts current work.
        if isWorking && isStopWord(text) {
            realtimeClient.sendInterrupt()
            voiceManager.enqueueSpeech("Stopping. ")
            return
        }
        realtimeClient.sendUserText(text)
    }

    private func handleBargeIn() {
        // Speech was already flushed inside VoiceManager. Nothing else to do —
        // the utterance itself will arrive via onUtterance and steer Claude.
    }

    private func isStopWord(_ text: String) -> Bool {
        let cleaned = text.lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return ["stop", "cancel", "stop claude", "cancel claude", "claude stop", "claude cancel"].contains(cleaned)
    }

    // MARK: - Gestures

    /// Tap: while conversing, toggle mute. Before the first conversation, start.
    /// While showing an error, retry.
    func handleTap() async {
        switch voiceState {
        case .idle:
            await startConversation(resume: sessionManager.hasSession)

        case .conversing:
            // Flip mute synchronously so the UI (mic icon + background) updates
            // this frame. No spoken confirmation and no flushSpeech — Claude
            // keeps talking and working while the user's mic is silenced.
            voiceManager.setMuted(!isMuted)

        case .connecting:
            // No-op — the connection attempt is already in flight.
            break

        case .error:
            await startConversation(resume: sessionManager.hasSession)
        }
    }

    /// 0.8s long-press: interrupt the current turn (same as saying "stop").
    func cancelProcessing() {
        guard isWorking else { return }
        AppLogger.shared.log("long-press interrupt", tag: "TAP")
        realtimeClient.sendInterrupt()
        voiceManager.enqueueSpeech("Stopping. ")
    }

    /// Shake: full reset — cancel any turn, drop the session, restart fresh.
    func resetToStart() async {
        AppLogger.shared.log("resetToStart()", tag: "RESET")
        realtimeClient.sendInterrupt()
        voiceManager.flushSpeech()
        voiceManager.stopDuplex()
        realtimeClient.disconnect()
        sessionManager.clearSession()
        // Kill any lingering non-duplex subprocess too.
        Task { [apiService] in await apiService.cancelSession() }
        await voiceManager.speakAndWait("Starting over.")
        await startConversation(resume: false)
    }

    // MARK: - Helpers

    private func transition(to state: VoiceState) async {
        voiceState = state
        statusMessage = statusFor(state)
    }

    private func statusFor(_ state: VoiceState) -> String {
        switch state {
        case .idle:        return "Tap anywhere to start"
        case .connecting:  return "Connecting…"
        case .conversing:
            if isMuted   { return "Muted — tap to unmute" }
            if isWorking { return "Claude Code is working…" }
            if isSpeaking { return "Speaking — talk anytime to interrupt" }
            if isListening { return "Listening…" }
            return "Ready — speak anytime"
        case .error(let msg): return msg
        }
    }
}
