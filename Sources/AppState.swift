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

    // Cancellable API call — stored so triple-tap can cancel it mid-flight
    private var currentApiTask: Task<(String, String), Error>?

    init() {
        voiceManager = VoiceManager()
        apiService = APIService()
        sessionManager = SessionManager()
    }

    // MARK: - Entry point

    func onAppear() async {
        let log = AppLogger.shared
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
        await voiceManager.speak("Got it. Sending to Claude Code now.")

        // Wrap the API call in a stored Task so triple-tap can cancel it.
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

        do {
            let (sessionId, response) = try await task.value
            currentApiTask = nil
            sessionManager.saveSession(id: sessionId)
            await handleIncomingResponse(response)
        } catch is CancellationError {
            currentApiTask = nil
            AppLogger.shared.log("API task cancelled by user", tag: "API")
            await voiceManager.speak("Cancelled. Tap anywhere to speak.")
            await transition(to: .waitingForInput)
        } catch {
            currentApiTask = nil
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
            if pausedFromListeningState == .listeningForChoice {
                await listenForSessionChoice()
            } else {
                await listenAndSend()
            }

        case .waitingForInput:
            await transition(to: .listeningForPrompt)
            await listenAndSend()

        case .error:
            await greet()

        case .idle:
            AppLogger.shared.log("tap received in .idle — starting greet()", tag: "TAP")
            await greet()

        case .processing:
            await voiceManager.speak("Still thinking. Triple tap to cancel.")
        }
    }

    // MARK: - Cancel processing

    func cancelProcessing() {
        guard voiceState == .processing else { return }
        AppLogger.shared.log("cancelProcessing() called", tag: "API")
        currentApiTask?.cancel()
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
