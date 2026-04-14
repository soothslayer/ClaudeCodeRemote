import Foundation
import Combine

// MARK: - Voice State

enum VoiceState: Equatable {
    case idle
    case speaking
    case listeningForChoice   // New session vs continue
    case listeningForPrompt   // User's coding request
    case processing           // Waiting for Claude Code response
    case waitingForInput      // Response read, tap to respond
    case error(String)
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    @Published private(set) var voiceState: VoiceState = .idle
    @Published private(set) var statusMessage: String = ""

    let voiceManager: VoiceManager
    let apiService: APIService
    let sessionManager: SessionManager

    init() {
        voiceManager = VoiceManager()
        apiService = APIService()
        sessionManager = SessionManager()
    }

    // MARK: - Entry point

    func onAppear() async {
        guard await voiceManager.requestPermissions() else {
            let msg = "Permissions required. Please open Settings and allow microphone and speech recognition access, then restart the app."
            await transition(to: .error(msg))
            await voiceManager.speak(msg)
            return
        }
        await greet()
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
            // Stop speaking and immediately listen
            voiceManager.stopSpeaking()
            await transition(to: .listeningForPrompt)
            await listenAndSend()

        case .waitingForInput:
            await transition(to: .listeningForPrompt)
            await listenAndSend()

        case .error:
            await greet()

        case .idle:
            await greet()

        case .listeningForChoice:
            voiceManager.stopListening()
            await greet()

        case .listeningForPrompt:
            // Stop early and submit whatever was heard
            voiceManager.stopListening()

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
        case .idle:                return ""
        case .speaking:            return "Speaking…"
        case .listeningForChoice:  return "Listening for your choice…"
        case .listeningForPrompt:  return "Listening… speak now"
        case .processing:          return "Claude Code is thinking…"
        case .waitingForInput:     return "Tap anywhere to respond"
        case .error(let msg):      return msg
        }
    }
}
