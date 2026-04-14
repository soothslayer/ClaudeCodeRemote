import SwiftUI

// MARK: - ContentView
// Full-screen, voice-first UI. Designed for blind users:
//   • Tap anywhere → respond
//   • Colors/icons are purely decorative (VoiceOver uses the accessibility label)
//   • Every state transition is announced by TTS in AppState

struct ContentView: View {

    @StateObject private var appState = AppState()
    @State private var showSettings = false

    var body: some View {
        GeometryReader { _ in
            ZStack {
                // Background fills the whole screen
                backgroundColor
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.4), value: appState.voiceState)

                // Central indicator + status text
                VStack(spacing: 32) {
                    Spacer()
                    stateIndicator
                    statusLabel
                    Spacer()
                }
            }
        }
        // Full-screen tap to respond
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await appState.handleTap() }
        }
        // Long press opens settings (for sighted caregiver to configure server URL)
        .onLongPressGesture(minimumDuration: 1.5) {
            showSettings = true
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        // Kick off the greeting when the view appears
        .task {
            await appState.onAppear()
        }
        // VoiceOver: entire screen is one element
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double tap to respond with your voice")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Animated state indicator

    private var stateIndicator: some View {
        ZStack {
            // Pulsing ring for listening states
            if isListening {
                Circle()
                    .stroke(indicatorColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 160, height: 160)
                    .scaleEffect(1.3)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isListening)
            }

            // Main circle
            Circle()
                .fill(indicatorColor)
                .frame(width: 130, height: 130)
                .shadow(color: indicatorColor.opacity(0.4), radius: 20, x: 0, y: 8)
                .animation(.easeInOut(duration: 0.3), value: appState.voiceState)

            // Icon
            Image(systemName: stateIcon)
                .font(.system(size: 52, weight: .medium))
                .foregroundColor(.white)
                .rotationEffect(isProcessing ? .degrees(360) : .zero)
                .animation(isProcessing ? .linear(duration: 2).repeatForever(autoreverses: false) : .default, value: isProcessing)
        }
    }

    // MARK: - Status text

    private var statusLabel: some View {
        Text(appState.statusMessage)
            .font(.title3)
            .fontWeight(.medium)
            .foregroundColor(.white.opacity(0.9))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 36)
            .animation(.none, value: appState.statusMessage)
    }

    // MARK: - Derived style values

    private var backgroundColor: Color {
        switch appState.voiceState {
        case .speaking:           return Color(red: 0.1, green: 0.2, blue: 0.6)
        case .pausedSpeaking:     return Color(red: 0.08, green: 0.12, blue: 0.35)
        case .listeningForChoice,
             .listeningForPrompt: return Color(red: 0.05, green: 0.4, blue: 0.15)
        case .pausedListening:    return Color(red: 0.03, green: 0.22, blue: 0.08)
        case .processing:         return Color(red: 0.5, green: 0.25, blue: 0.0)
        case .waitingForInput:    return Color(red: 0.15, green: 0.1, blue: 0.3)
        case .error:              return Color(red: 0.4, green: 0.05, blue: 0.05)
        case .idle:               return Color.black
        }
    }

    private var indicatorColor: Color {
        switch appState.voiceState {
        case .speaking:           return Color.blue
        case .pausedSpeaking:     return Color.blue.opacity(0.5)
        case .listeningForChoice,
             .listeningForPrompt: return Color.green
        case .pausedListening:    return Color.green.opacity(0.5)
        case .processing:         return Color.orange
        case .waitingForInput:    return Color.purple
        case .error:              return Color.red
        case .idle:               return Color.gray
        }
    }

    private var stateIcon: String {
        switch appState.voiceState {
        case .speaking:           return "speaker.wave.3.fill"
        case .pausedSpeaking:     return "pause.fill"
        case .listeningForChoice,
             .listeningForPrompt: return "mic.fill"
        case .pausedListening:    return "pause.fill"
        case .processing:         return "gearshape.fill"
        case .waitingForInput:    return "hand.tap.fill"
        case .error:              return "exclamationmark.triangle.fill"
        case .idle:               return "waveform"
        }
    }

    private var isListening: Bool {
        appState.voiceState == .listeningForChoice || appState.voiceState == .listeningForPrompt
    }

    private var isPaused: Bool {
        appState.voiceState == .pausedSpeaking || appState.voiceState == .pausedListening
    }

    private var isProcessing: Bool {
        appState.voiceState == .processing
    }

    private var accessibilityLabel: String {
        switch appState.voiceState {
        case .speaking:           return "Claude Code is speaking. Double tap to pause."
        case .pausedSpeaking:     return "Speaking paused. Double tap to resume."
        case .listeningForChoice: return "Listening. Say new session or continue. Double tap to pause."
        case .listeningForPrompt: return "Listening for your message. Speak now. Double tap to pause."
        case .pausedListening:    return "Listening paused. Double tap to resume."
        case .processing:         return "Claude Code is processing your request. Please wait."
        case .waitingForInput:    return "Ready for your response. Double tap to speak."
        case .error(let msg):     return "Error: \(msg). Double tap to try again."
        case .idle:               return "Claude Code Remote. Double tap to start."
        }
    }
}

#Preview {
    ContentView()
}
