import Foundation
import Combine

// MARK: - Voice State

enum VoiceState: Equatable {
    case idle
    case speaking
    case pausedSpeaking       // Speech paused; tap to resume
    case listeningForChoice   // New session vs continue
    case listeningForPrompt   // User's coding request
    case pausedListening      // Listening paused; tap to resume
    case processing           // Waiting for Claude Code response
    case waitingForInput      // Response read, tap to respond
    case error(String)
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    @Published private(set) var voiceState: VoiceState = .idle
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isRequestingPermissions = false

    let voiceManager: VoiceManager
    let apiService: APIService
    let sessionManager: SessionManager

    // Pause support
    private var isPaused = false
    private var pausedFromListeningState: VoiceState = .listeningForPrompt

    // Cancellable API call — stored so long-press can cancel it mid-flight
    private var currentApiTask: Task<(String, String), Error>?

    init() {
        voiceManager = VoiceManager()
        apiService = APIService()
        sessionManager = SessionManager()
    }

    // MARK: - Entry point

    func onAppear() async {
        let log = AppLogger.shared
        print("start")
        log.log("onAppear start", tag: "INIT")

        isRequestingPermissions = true
        log.log("requesting permissions…", tag: "INIT")
        let granted = await voiceManager.requestPermissions()
        isRequestingPermissions = false
        log.log("permissions granted=\(granted)", tag: "INIT")

        guard granted else {
            let msg = "Permissions required. Please open Settings and allow microphone and speech recognition access, then restart the app."
            log.log("permissions denied — showing error", tag: "INIT")
            await transition(to: .error(msg))
            return
        }

        log.log("transitioning to .idle — waiting for tap", tag: "INIT")
        await transition(to: .idle)
    }

    // MARK: - Magic setup link

    /// Handles clauderemote://setup?url=https://…
    /// Saves the server URL and speaks a confirmation so the user doesn't need
    /// to open Settings at all.
    func handleSetupLink(_ url: URL) async {
        guard url.scheme?.lowercased() == "clauderemote",
              url.host?.lowercased() == "setup",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let serverURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              !serverURL.isEmpty else {
            AppLogger.shared.log("Ignored unrecognised deep link: \(url)", tag: "LINK")
            return
        }

        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        AppLogger.shared.log("Server URL set via magic link: \(serverURL)", tag: "LINK")

        // Speak confirmation regardless of current state so the user knows it worked
        await voiceManager.speak("Server connected. You're all set. Tap anywhere to start.")

        // If the app was idle (first launch), transition stays at .idle so one tap starts
        // If the app was already running in another state, leave it as-is
    }

    // MARK: - Greeting

    private func greet() async {
        let log = AppLogger.shared
        log.log("greet() start, hasSession=\(sessionManager.hasSession)", tag: "GREET")
        await transition(to: .speaking)
        let greeting: String
        if sessionManager.hasSession {
            greeting = "Welcome back to Claude Code Remote. Say new session to start fresh, or say continue to pick up where you left off."
        } else {
            greeting = "Welcome to Claude Code Remote. Say new session to get started."
        }
        log.log("calling speak(greeting)…", tag: "GREET")
        await voiceManager.speak(greeting)
        log.log("speak(greeting) returned", tag: "GREET")
        await transition(to: .listeningForChoice)
        await listenForSessionChoice()
    }

    // MARK: - Session choice

    private func listenForSessionChoice() async {
        guard let text = await voiceManager.listen() else {
            if isPaused {
                pausedFromListeningState = .listeningForChoice
                await transition(to: .pausedListening)
                return
            }
            await voiceManager.speak("I didn't catch that. Tap anywhere to try again.")
            await transition(to: .waitingForInput)
            return
        }
        let lower = text.lowercased()
        if lower.contains("continue") || lower.contains("last") || lower.contains("back") {
            await continueSession()
        } else {
            await startNewSession()
        }
    }

    // MARK: - New session

    private func startNewSession() async {
        sessionManager.clearSession()
        await transition(to: .speaking)
        await voiceManager.speak("Starting a new session. What would you like to work on?")
        await transition(to: .listeningForPrompt)
        await listenAndSend()
    }

    // MARK: - Continue session

    private func continueSession() async {
        await transition(to: .speaking)
        if sessionManager.hasSession {
            await voiceManager.speak("Continuing your last session. What would you like to say?")
        } else {
            await voiceManager.speak("No previous session found. Starting a new session. What would you like to work on?")
        }
        await transition(to: .listeningForPrompt)
        await listenAndSend()
    }

    // MARK: - Core listen → send → speak loop

    func listenAndSend() async {
        guard let text = await voiceManager.listen() else {
            if isPaused {
                pausedFromListeningState = .listeningForPrompt
                await transition(to: .pausedListening)
                return
            }
            await voiceManager.speak("I didn't catch that. Tap anywhere to try again.")
            await transition(to: .waitingForInput)
            return
        }

        await transition(to: .processing)

        // Create and store the task BEFORE speaking so cancelProcessing()
        // can cancel it even if called during the "Got it" confirmation speech.
        let task = Task<(String, String), Error> {
            if let sessionId = self.sessionManager.lastSessionId {
                let r = try await self.apiService.sendMessage(sessionId: sessionId, prompt: text)
                return (r.sessionId, r.response)
            } else {
                let r = try await self.apiService.newSession(prompt: text)
                return (r.sessionId, r.response)
            }
        }
        currentApiTask = task

        await voiceManager.speak("Got it. Sending to Claude Code now.")

        // Periodic check-in task — two purposes:
        //  1. Speaks aloud so the user knows work is still in progress
        //  2. Keeps the AVAudioSession active so iOS doesn't suspend the app
        //     when the user backgrounds it (UIBackgroundModes: [audio])
        let checkInTask = Task { @MainActor [weak self] in
            let intervals: [UInt64] = [
                90_000_000_000,   // first check-in after 90 s
                120_000_000_000,  // then every 2 min
            ]
            var iteration = 0
            while true {
                let delay = iteration < intervals.count ? intervals[iteration] : intervals.last!
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self, !Task.isCancelled, voiceState == .processing else { return }
                let elapsed = iteration == 0 ? "a minute and a half" : "\(Int((iteration + 1) * 2)) minutes"
                await voiceManager.speak("Still working, \(elapsed) in.")
                iteration += 1
            }
        }

        do {
            let (sessionId, response) = try await task.value
            checkInTask.cancel()
            currentApiTask = nil
            // Guard: cancelProcessing() may have already moved us out of .processing
            guard voiceState == .processing else { return }
            sessionManager.saveSession(id: sessionId)
            await handleIncomingResponse(response)
        } catch is CancellationError {
            checkInTask.cancel()
            currentApiTask = nil
            AppLogger.shared.log("API task cancelled by user", tag: "API")
            // cancelProcessing() already updated the UI synchronously; nothing else needed.
        } catch {
            checkInTask.cancel()
            currentApiTask = nil
            guard voiceState == .processing else { return }
            let msg = errorMessage(for: error)
            await transition(to: .error(msg))
            await voiceManager.speak("Error: \(msg). Tap anywhere to try again.")
            await transition(to: .waitingForInput)
        }
    }

    // MARK: - Handle incoming response

    func handleIncomingResponse(_ response: String) async {
        await transition(to: .speaking)
        await voiceManager.speak(response)
        await voiceManager.speak("Tap anywhere to respond.")
        await transition(to: .waitingForInput)
    }

    // MARK: - Tap handler

    func handleTap() async {
        switch voiceState {
        case .speaking:
            voiceManager.pauseSpeaking()
            await transition(to: .pausedSpeaking)

        case .pausedSpeaking:
            voiceManager.resumeSpeaking()
            await transition(to: .speaking)

        case .listeningForChoice:
            isPaused = true
            voiceManager.stopListening()
            // listenForSessionChoice() will check isPaused and park in .pausedListening

        case .listeningForPrompt:
            isPaused = true
            voiceManager.stopListening()
            // listenAndSend() will check isPaused and park in .pausedListening

        case .pausedListening:
            isPaused = false
            await transition(to: pausedFromListeningState)
            await voiceManager.speak("Go ahead.")
            if pausedFromListeningState == .listeningForChoice {
                await listenForSessionChoice()
            } else {
                await listenAndSend()
            }

        case .waitingForInput:
            await transition(to: .listeningForPrompt)
            await voiceManager.speak("Go ahead.")
            await listenAndSend()

        case .error:
            await greet()

        case .idle:
            AppLogger.shared.log("tap received in .idle — starting greet()", tag: "TAP")
            await greet()

        case .processing:
            await voiceManager.speak("Still thinking. Hold to cancel.")
        }
    }

    // MARK: - Cancel processing

    func cancelProcessing() {
        guard voiceState == .processing else { return }
        AppLogger.shared.log("cancelProcessing() called", tag: "API")

        // Cancel the network task (may be nil if we're still in the "Got it" speech).
        currentApiTask?.cancel()
        currentApiTask = nil

        // Stop any in-progress TTS so we don't keep speaking over the cancellation.
        voiceManager.stopSpeaking()

        // Update UI synchronously — this is what was missing. The catch block in
        // listenAndSend() won't update state because it now relies on this path.
        voiceState = .waitingForInput
        statusMessage = VoiceState.waitingForInput.displayMessage

        // Speak the confirmation on an async task (can't await from a sync func).
        Task { @MainActor [weak self] in
            guard let self else { return }
            await voiceManager.speak("Cancelled. Tap anywhere to speak.")
        }
    }

    // MARK: - Helpers

    private func transition(to state: VoiceState) async {
        voiceState = state
        statusMessage = state.displayMessage
    }

    private func errorMessage(for error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .serverNotConfigured:
                return "Server URL is not configured. Ask someone to set it up by long pressing the screen."
            case .serverUnreachable:
                return "Cannot reach the server. Make sure your computer is running the bot."
            case .timeout:
                return "The request timed out. Claude Code may be busy. Try again."
            case .serverError(let msg):
                return "Server error: \(msg)"
            }
        }
        return error.localizedDescription
    }
}

// MARK: - VoiceState display text

extension VoiceState {
    var displayMessage: String {
        switch self {
        case .idle:                return "Tap anywhere to start"
        case .speaking:            return "Speaking…"
        case .pausedSpeaking:      return "Paused — tap to resume"
        case .listeningForChoice:  return "Listening for your choice…"
        case .listeningForPrompt:  return "Listening… speak now"
        case .pausedListening:     return "Paused — tap to resume"
        case .processing:          return "Claude Code is thinking…"
        case .waitingForInput:     return "Tap anywhere to respond"
        case .error(let msg):      return msg
        }
    }
}
