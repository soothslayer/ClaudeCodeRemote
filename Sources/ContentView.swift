import SwiftUI

// MARK: - ContentView
// Full-screen voice-first UI. Full-duplex model: the mic is always live
// during .conversing (unless muted). Visual sub-states (speaking / listening
// / working) can overlap and are shown as combined ring + fill colors.
//
// Gestures:
//   • tap                — mute/unmute (or start, from .idle/.error)
//   • long press 0.8 s   — interrupt Claude while working
//   • long press 1.5 s   — Settings
//   • shake              — hard reset

struct ContentView: View {

    @StateObject private var appState = AppState()
    @State private var showSettings = false
    @State private var longPressCancelled = false

    var body: some View {
        GeometryReader { _ in
            ZStack {
                backgroundColor
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.4), value: paletteKey)

                VStack(spacing: 32) {
                    Spacer()
                    stateIndicator
                    statusLabel
                    Spacer()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !appState.isRequestingPermissions else { return }
            Task { await appState.handleTap() }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.8).onEnded { _ in
                guard !appState.isRequestingPermissions else { return }
                guard appState.isWorking else { return }
                longPressCancelled = true
                appState.cancelProcessing()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    longPressCancelled = false
                }
            }
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 1.5).onEnded { _ in
                guard !appState.isRequestingPermissions else { return }
                guard !longPressCancelled else { return }
                showSettings = true
            }
        )
        .onShake {
            guard !appState.isRequestingPermissions else { return }
            Task { await appState.resetToStart() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onOpenURL { url in
            Task { await appState.handleSetupLink(url) }
        }
        .task {
            await appState.onAppear()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double tap to mute or unmute. Long press to interrupt. Shake to start over.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Indicator

    private var stateIndicator: some View {
        ZStack {
            // Outer ring animates for whichever activity is live.
            if appState.isListening && !appState.isMuted {
                Circle()
                    .stroke(Color.green.opacity(0.6), lineWidth: 3)
                    .frame(width: 170, height: 170)
                    .scaleEffect(1.15)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: appState.isListening)
            } else if !appState.isMuted && appState.voiceState == .conversing {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 2)
                    .frame(width: 170, height: 170)
            }

            Circle()
                .fill(indicatorColor)
                .frame(width: 130, height: 130)
                .shadow(color: indicatorColor.opacity(0.5), radius: 20, x: 0, y: 8)
                .animation(.easeInOut(duration: 0.3), value: paletteKey)

            Image(systemName: stateIcon)
                .font(.system(size: 52, weight: .medium))
                .foregroundColor(.white)
                .rotationEffect(appState.isWorking ? .degrees(360) : .zero)
                .animation(
                    appState.isWorking
                        ? .linear(duration: 2).repeatForever(autoreverses: false)
                        : .default,
                    value: appState.isWorking
                )
        }
    }

    private var statusLabel: some View {
        Text(appState.statusMessage)
            .font(.title3)
            .fontWeight(.medium)
            .foregroundColor(.white.opacity(0.9))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 36)
            .animation(.none, value: appState.statusMessage)
    }

    // MARK: - Palette

    /// Cheap Equatable key that captures every field the palette depends on.
    private var paletteKey: String {
        "\(appState.voiceState)-\(appState.isSpeaking)-\(appState.isWorking)-\(appState.isMuted)"
    }

    private var backgroundColor: Color {
        switch appState.voiceState {
        case .idle:        return .black
        case .connecting:  return Color(red: 0.12, green: 0.15, blue: 0.35)
        case .error:       return Color(red: 0.40, green: 0.05, blue: 0.05)
        case .conversing:
            if appState.isMuted   { return Color(red: 0.10, green: 0.10, blue: 0.15) }
            if appState.isWorking { return Color(red: 0.50, green: 0.25, blue: 0.00) }
            if appState.isSpeaking { return Color(red: 0.10, green: 0.20, blue: 0.60) }
            return Color(red: 0.05, green: 0.40, blue: 0.15)
        }
    }

    private var indicatorColor: Color {
        switch appState.voiceState {
        case .idle:        return .gray
        case .connecting:  return .indigo
        case .error:       return .red
        case .conversing:
            if appState.isMuted   { return .gray }
            if appState.isWorking { return .orange }
            if appState.isSpeaking { return .blue }
            return .green
        }
    }

    private var stateIcon: String {
        switch appState.voiceState {
        case .idle:        return "waveform"
        case .connecting:  return "antenna.radiowaves.left.and.right"
        case .error:       return "exclamationmark.triangle.fill"
        case .conversing:
            if appState.isMuted   { return "mic.slash.fill" }
            if appState.isWorking { return "gearshape.fill" }
            if appState.isSpeaking { return "speaker.wave.3.fill" }
            return "mic.fill"
        }
    }

    private var accessibilityLabel: String {
        switch appState.voiceState {
        case .idle:        return "Claude Code Remote. Tap to start."
        case .connecting:  return "Connecting to Claude Code."
        case .error(let msg): return "Error: \(msg). Tap to retry."
        case .conversing:
            if appState.isMuted   { return "Muted. Tap to unmute." }
            if appState.isWorking { return "Claude Code is working. Speak to steer, or long press to stop." }
            if appState.isSpeaking { return "Claude Code is speaking. Speak to interrupt." }
            if appState.isListening { return "Listening to you now." }
            return "Ready. Speak anytime."
        }
    }
}

#Preview {
    ContentView()
}
