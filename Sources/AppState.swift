import Foundation
import Combine

// MARK: - Voice State (headline UI state)
// The app is a VoIP client whose only contact is Claude Code. Every
// conversation is a real CallKit call: dial → ringback → answered → on call.

enum VoiceState: Equatable {
    case idle           // ready to call
    case dialing        // CallKit call placed, ringback playing, WS connecting
    case onCall         // duplex live — sub-states in isSpeaking/isListening/isWorking
    case error(String)
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    // Headline UI state
    @Published private(set) var voiceState: VoiceState = .idle
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isRequestingPermissions = false
    /// Set when the server answers; drives the in-call duration timer.
    @Published private(set) var callConnectedAt: Date?

    // Sub-states (all valid simultaneously during .onCall)
    @Published private(set) var isSpeaking = false          // TTS audible
    @Published private(set) var isListening = false         // mic hot + hearing user
    @Published private(set) var isWorking = false           // Claude Code is thinking
    @Published private(set) var isMuted = false

    // Collaborators
    let voiceManager: VoiceManager
    let callManager: CallManager
    let realtimeClient: RealtimeClient
    let apiService: APIService
    let sessionManager: SessionManager

    private var everCalled = false
    private var pendingResume = false
    /// True when CallKit refused the call and we're running a plain in-app
    /// conversation instead (old behaviour).
    private var usingFallbackAudio = false
    private var lastToolActivityAt: Date = .distantPast
    private var subscriptions = Set<AnyCancellable>()

    init() {
        voiceManager = VoiceManager()
        callManager = CallManager()
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
            .sink { [weak self] in
                self?.isMuted = $0
                self?.refreshStatus()
            }
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

        // CallKit callbacks — the system is the source of truth for the call.
        callManager.onConfigureAudioSession = { [weak self] in
            self?.voiceManager.configureCallAudioSession()
        }
        callManager.onAudioSessionActivated = { [weak self] in
            self?.callAudioActivated()
        }
        callManager.onCallEnded = { [weak self] in
            self?.callDidEnd()
        }
        callManager.onMuteChanged = { [weak self] muted in
            self?.applyMute(muted)
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

        // Blind-first: opening the app IS the intent to call.
        await placeCall(resume: sessionManager.hasSession)
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

        if !everCalled {
            await voiceManager.speakAndWait("Server connected. Tap Call to ring Claude Code.")
        }
    }

    // MARK: - Placing the call

    func placeCall(resume: Bool) async {
        guard voiceState == .idle || isErrorState else { return }
        everCalled = true
        pendingResume = resume
        usingFallbackAudio = false
        await transition(to: .dialing)

        voiceManager.callKitOwnsSession = true
        let ok = await callManager.startCall()
        if !ok {
            // CallKit refused (rare — e.g. restricted region). Fall back to a
            // plain in-app conversation exactly like the old app.
            AppLogger.shared.log("CallKit unavailable — falling back to in-app audio", tag: "CALL")
            voiceManager.callKitOwnsSession = false
            usingFallbackAudio = true
            await startFallbackConversation(resume: resume)
        }
        // else: flow continues in callAudioActivated() once CallKit
        // activates the audio session.
    }

    private var isErrorState: Bool {
        if case .error = voiceState { return true }
        return false
    }

    /// CallKit activated the audio session — dial tone time.
    private func callAudioActivated() {
        // Re-activation mid-call (after a hold / Siri) — just resume.
        guard !voiceManager.isDuplexRunning else {
            voiceManager.resumeEngineIfNeeded()
            return
        }
        guard voiceState == .dialing else { return }

        Task { @MainActor in
            do {
                try voiceManager.startDuplex()
            } catch {
                await failCall("Could not start audio: \(error.localizedDescription)")
                return
            }

            voiceManager.startRingback()
            let connected = await realtimeClient.connect()
            // The user may have hung up while it was ringing.
            guard voiceState == .dialing else { return }
            voiceManager.stopRingback()

            if connected {
                callManager.reportConnected()
                callConnectedAt = Date()
                await transition(to: .onCall)
                await voiceManager.speakAndWait(
                    pendingResume
                        ? "Claude Code. Welcome back — I've still got our session."
                        : "Claude Code here. What are we working on?"
                )
                realtimeClient.startSession(resume: pendingResume)
            } else {
                await failCall("Claude Code isn't answering. Make sure the server is running, then call again.")
            }
        }
    }

    /// The server never answered — speak the reason, then end the CallKit call.
    private func failCall(_ msg: String) async {
        voiceManager.stopRingback()
        realtimeClient.disconnect()
        await voiceManager.speakAndWait(msg)     // engine still up — speak first
        callManager.reportFailed()               // no delegate round-trip; tear down here
        voiceManager.stopDuplex()
        voiceManager.callKitOwnsSession = false
        callConnectedAt = nil
        await transition(to: .error(msg))
    }

    /// Fallback path when CallKit refuses — the pre-VoIP behaviour.
    private func startFallbackConversation(resume: Bool) async {
        do {
            try voiceManager.startDuplex()
        } catch {
            let msg = "Could not start audio: \(error.localizedDescription)"
            await transition(to: .error(msg))
            await voiceManager.speakAndWait(msg)
            return
        }
        let connected = await realtimeClient.connect()
        if connected {
            callConnectedAt = Date()
            await transition(to: .onCall)
            await voiceManager.speakAndWait(
                resume
                    ? "Reconnecting to your session."
                    : "Starting a new session. Say hello when you're ready."
            )
            realtimeClient.startSession(resume: resume)
        } else {
            voiceManager.stopDuplex()
            let msg = "Claude Code isn't answering. Make sure the server is running, then call again."
            await transition(to: .error(msg))
            await voiceManager.speakAndWait(msg)
        }
    }

    // MARK: - Ending the call

    /// Hang up (End button, or lock-screen End via CallKit).
    func hangUp() async {
        if callManager.hasActiveCall {
            await callManager.endCall()          // → perform(End) → callDidEnd()
        } else if usingFallbackAudio {
            callDidEnd()
        }
    }

    /// Single teardown point — fires for every way a call can end.
    /// Note: this does NOT interrupt server-side work. If Claude is mid-task
    /// when you hang up, it keeps working; call back later and resume.
    private func callDidEnd() {
        AppLogger.shared.log("call ended", tag: "CALL")
        voiceManager.stopRingback()
        voiceManager.flushSpeech()
        voiceManager.stopDuplex()
        realtimeClient.disconnect()
        voiceManager.callKitOwnsSession = false
        usingFallbackAudio = false
        callConnectedAt = nil
        if voiceManager.isMuted { voiceManager.setMuted(false) }
        // Synchronous on purpose — an async hop here could land AFTER a
        // redial has already moved us to .dialing and stomp the new call.
        voiceState = .idle
        statusMessage = statusFor(.idle)
    }

    // MARK: - Server events

    private func handleServerEvent(_ event: ServerEvent) {
        switch event {
        case .connected(let reconnect):
            if reconnect, voiceState == .onCall {
                voiceManager.enqueueSpeech("Reconnected. ")
            }

        case .disconnected:
            if voiceState == .onCall {
                voiceManager.enqueueSpeech("Connection dropped. Reconnecting. ")
            }

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
            refreshStatus()

        case .status(let working):
            isWorking = working
            if !working { lastToolActivityAt = .distantPast }
            refreshStatus()

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

    // MARK: - Mute

    /// Toggle mute. Routed through CallKit so the lock-screen button, AirPods,
    /// and our UI all stay in sync; the mic change lands in applyMute().
    func toggleMute() async {
        guard voiceState == .onCall else { return }
        let willMute = !isMuted
        if callManager.hasActiveCall {
            await callManager.requestMute(willMute)
        } else {
            applyMute(willMute)                  // fallback path — no CallKit
        }
    }

    private func applyMute(_ muted: Bool) {
        guard muted != voiceManager.isMuted else { return }
        voiceManager.setMuted(muted)
        // Phone-call mute is mic-only, so this confirmation is audible even
        // while muted.
        voiceManager.enqueueSpeech(muted ? "Muted. " : "Listening. ")
        refreshStatus()
    }

    // MARK: - Gestures

    /// Background tap: idle/error → call; on call → toggle mute.
    func handleTap() async {
        switch voiceState {
        case .idle, .error:
            await placeCall(resume: sessionManager.hasSession)
        case .onCall:
            await toggleMute()
        case .dialing:
            break
        }
    }

    /// 0.8s long-press: interrupt the current turn (same as saying "stop").
    func cancelProcessing() {
        guard isWorking else { return }
        AppLogger.shared.log("long-press interrupt", tag: "TAP")
        realtimeClient.sendInterrupt()
        voiceManager.enqueueSpeech("Stopping. ")
    }

    /// Shake: full reset — hang up, drop the session, redial fresh.
    func resetToStart() async {
        AppLogger.shared.log("resetToStart()", tag: "RESET")
        realtimeClient.sendInterrupt()
        sessionManager.clearSession()
        // Kill any lingering non-duplex subprocess too.
        Task { [apiService] in await apiService.cancelSession() }
        await hangUp()
        // CXEndCallAction's perform (→ callDidEnd) can trail the transaction
        // completion — wait for the teardown before redialing.
        let deadline = Date().addingTimeInterval(3)
        while callManager.hasActiveCall && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await voiceManager.speakAndWait("Starting over.")
        await placeCall(resume: false)
    }

    // MARK: - Helpers

    private func transition(to state: VoiceState) async {
        voiceState = state
        statusMessage = statusFor(state)
    }

    private func refreshStatus() {
        statusMessage = statusFor(voiceState)
    }

    private func statusFor(_ state: VoiceState) -> String {
        switch state {
        case .idle:        return everCalled ? "Call ended" : "Ready to call"
        case .dialing:     return "Calling Claude Code…"
        case .onCall:
            if isMuted   { return "Muted — Claude can't hear you" }
            if isWorking { return "Working on it…" }
            if isSpeaking { return "Talking — speak anytime to interrupt" }
            if isListening { return "Listening…" }
            return "On call — speak anytime"
        case .error(let msg): return msg
        }
    }
}
