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

    init() {
        voiceManager = VoiceManager()
        apiService = APIService()
        sessionManager = SessionManager()
    }

    // MARK: - Entry point

    func onAppear() async {
        isRequestingPermissions = true
        let granted = await voiceManager.requestPermissions()
        isRequestingPermissions = false

        guard granted else {
            let msg = "Permissions required. Please open Settings and allow microphone and speech recognition access, then restart the app."
            await transition(to: .error(msg))
            // Don't try to speak — we may not have audio permissions yet.
            // VoiceOver will read the accessibility label instead.
            return
        }

        // Stay in .idle and wait for a deliberate tap before touching the audio
        // session. Attempting to speak immediately after permission dialogs dismiss
        // can cause AVSpeechSynthesizer to silently fail due to audio session
        // timing issues on first launch.
        await transition(to: .idle)
    }

    // MARK: - Greeting

    private func greet() async {
        await transition(to: .speaking)
        let greeting: String
        if sessionManager.hasSession {
            greeting = "Welcome back to Claude Code Remote. Say new session to start fresh, or say continue to pick up where you left off."
        } else {
            greeting = "Welcome to Claude Code Remote. Say new session to get started."
        }
        await voiceManager.speak(greeting)
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

        do {
            let response: String
            if let sessionId = sessionManager.lastSessionId {
                let result = try await apiService.sendMessage(sessionId: sessionId, prompt: text)
                sessionManager.saveSession(id: result.sessionId)
                response = result.response
            } else {
                let result = try await apiService.newSession(prompt: text)
                sessionManager.saveSession(id: result.sessionId)
                response = result.response
            }
            await handleIncomingResponse(response)
        } catch {
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
            await greet()

        case .processing:
            await voiceManager.speak("Still waiting for Claude Code. Please be patient.")
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
