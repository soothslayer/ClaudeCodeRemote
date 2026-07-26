import SwiftUI
import AVKit

// MARK: - ContentView
// VoIP call UI: the app is a phone whose only contact is Claude Code.
// Idle shows a contact card with a green Call button; on a call you get the
// familiar call layout — name + duration up top, a state avatar in the
// middle, and Mute / Audio route / End controls at the bottom.
//
// Gestures (kept from the voice-first design, all off the buttons):
//   • tap background     — mute/unmute (or call, from idle/error)
//   • long press 0.8 s   — interrupt Claude while working
//   • long press 1.5 s   — Settings
//   • shake              — hard reset (hang up, drop session, redial)

struct ContentView: View {

    @StateObject private var appState = AppState()
    @State private var showSettings = false
    @State private var longPressCancelled = false

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: paletteKey)

            VStack(spacing: 0) {
                header
                    .padding(.top, 60)
                Spacer()
                avatar
                statusLabel
                    .padding(.top, 28)
                Spacer()
                controls
                    .padding(.bottom, 60)
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
    }

    // MARK: - Header (contact name + call state / duration)

    private var header: some View {
        VStack(spacing: 8) {
            Text("Claude Code")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white)

            Group {
                switch appState.voiceState {
                case .idle:
                    Text("dev machine")
                        .foregroundColor(.white.opacity(0.6))
                case .dialing:
                    Text("calling…")
                        .foregroundColor(.white.opacity(0.8))
                case .onCall:
                    if let start = appState.callConnectedAt {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(Self.durationString(from: start, to: context.date))
                                .monospacedDigit()
                                .foregroundColor(.white.opacity(0.8))
                        }
                    } else {
                        Text("connected")
                            .foregroundColor(.white.opacity(0.8))
                    }
                case .error:
                    Text("call failed")
                        .foregroundColor(.red.opacity(0.9))
                }
            }
            .font(.system(size: 19, weight: .regular))
        }
        .accessibilityElement(children: .combine)
    }

    private static func durationString(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    // MARK: - Avatar (state indicator)

    private var avatar: some View {
        ZStack {
            if appState.isListening && !appState.isMuted {
                Circle()
                    .stroke(Color.green.opacity(0.6), lineWidth: 3)
                    .frame(width: 190, height: 190)
                    .scaleEffect(1.12)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: appState.isListening)
            } else if appState.voiceState == .onCall || appState.voiceState == .dialing {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 2)
                    .frame(width: 190, height: 190)
                    .scaleEffect(appState.voiceState == .dialing ? 1.12 : 1.0)
                    .animation(
                        appState.voiceState == .dialing
                            ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                            : .default,
                        value: appState.voiceState == .dialing
                    )
            }

            Circle()
                .fill(avatarColor)
                .frame(width: 150, height: 150)
                .shadow(color: avatarColor.opacity(0.5), radius: 20, x: 0, y: 8)
                .animation(.easeInOut(duration: 0.3), value: paletteKey)

            Image(systemName: avatarIcon)
                .font(.system(size: 58, weight: .medium))
                .foregroundColor(.white)
                .rotationEffect(appState.isWorking ? .degrees(360) : .zero)
                .animation(
                    appState.isWorking
                        ? .linear(duration: 2).repeatForever(autoreverses: false)
                        : .default,
                    value: appState.isWorking
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(avatarAccessibilityLabel)
        .accessibilityHint(avatarAccessibilityHint)
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            guard !appState.isRequestingPermissions else { return }
            Task { await appState.handleTap() }
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

    // MARK: - Call controls

    @ViewBuilder
    private var controls: some View {
        switch appState.voiceState {
        case .idle, .error:
            CallControlButton(
                icon: "phone.fill",
                label: appState.voiceState == .idle ? "Call" : "Call again",
                background: .green,
                size: 84
            ) {
                Task { await appState.placeCall(resume: appState.sessionManager.hasSession) }
            }
            .accessibilityLabel("Call Claude Code")
            .accessibilityHint("Places a voice call to Claude Code on your dev machine.")

        case .dialing:
            CallControlButton(
                icon: "phone.down.fill",
                label: "Cancel",
                background: .red,
                size: 84
            ) {
                Task { await appState.hangUp() }
            }
            .accessibilityLabel("Cancel call")

        case .onCall:
            HStack(spacing: 44) {
                CallControlButton(
                    icon: appState.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: appState.isMuted ? "Unmute" : "Mute",
                    background: appState.isMuted ? .white : Color.white.opacity(0.22),
                    foreground: appState.isMuted ? .black : .white,
                    size: 72
                ) {
                    Task { await appState.toggleMute() }
                }
                .accessibilityLabel(appState.isMuted ? "Unmute microphone" : "Mute microphone")

                audioRouteButton

                CallControlButton(
                    icon: "phone.down.fill",
                    label: "End",
                    background: .red,
                    size: 72
                ) {
                    Task { await appState.hangUp() }
                }
                .accessibilityLabel("End call")
                .accessibilityHint("Hangs up. Claude keeps working on any running task; call back to resume.")
            }
        }
    }

    /// The system audio-route picker (speaker / receiver / Bluetooth), dressed
    /// as a call button. Fully VoiceOver accessible out of the box.
    private var audioRouteButton: some View {
        VStack(spacing: 10) {
            AudioRoutePickerView()
                .frame(width: 72, height: 72)
                .background(Color.white.opacity(0.22))
                .clipShape(Circle())
            Text("Audio")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
        }
    }

    // MARK: - Palette

    /// Cheap Equatable key that captures every field the palette depends on.
    private var paletteKey: String {
        "\(appState.voiceState)-\(appState.isSpeaking)-\(appState.isWorking)-\(appState.isMuted)"
    }

    private var background: some View {
        LinearGradient(
            colors: [backgroundColor, backgroundColor.opacity(0.6), .black],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var backgroundColor: Color {
        switch appState.voiceState {
        case .idle:        return Color(red: 0.09, green: 0.09, blue: 0.12)
        case .dialing:     return Color(red: 0.12, green: 0.15, blue: 0.35)
        case .error:       return Color(red: 0.40, green: 0.05, blue: 0.05)
        case .onCall:
            if appState.isMuted   { return Color(red: 0.10, green: 0.10, blue: 0.15) }
            if appState.isWorking { return Color(red: 0.50, green: 0.25, blue: 0.00) }
            if appState.isSpeaking { return Color(red: 0.10, green: 0.20, blue: 0.60) }
            return Color(red: 0.05, green: 0.40, blue: 0.15)
        }
    }

    private var avatarColor: Color {
        switch appState.voiceState {
        case .idle:        return Color(red: 0.35, green: 0.30, blue: 0.60)
        case .dialing:     return .indigo
        case .error:       return .red
        case .onCall:
            if appState.isMuted   { return .gray }
            if appState.isWorking { return .orange }
            if appState.isSpeaking { return .blue }
            return .green
        }
    }

    private var avatarIcon: String {
        switch appState.voiceState {
        case .idle:        return "waveform"
        case .dialing:     return "phone.arrow.up.right.fill"
        case .error:       return "exclamationmark.triangle.fill"
        case .onCall:
            if appState.isMuted   { return "mic.slash.fill" }
            if appState.isWorking { return "gearshape.fill" }
            if appState.isSpeaking { return "speaker.wave.3.fill" }
            return "mic.fill"
        }
    }

    // MARK: - Accessibility

    private var avatarAccessibilityLabel: String {
        switch appState.voiceState {
        case .idle:        return "Claude Code. Ready to call."
        case .dialing:     return "Calling Claude Code."
        case .error(let msg): return "Call failed: \(msg)."
        case .onCall:
            if appState.isMuted   { return "On call, muted." }
            if appState.isWorking { return "Claude Code is working. Speak to steer, or long press to stop." }
            if appState.isSpeaking { return "Claude Code is talking. Speak to interrupt." }
            if appState.isListening { return "Listening to you now." }
            return "On call. Speak anytime."
        }
    }

    private var avatarAccessibilityHint: String {
        switch appState.voiceState {
        case .idle, .error: return "Double tap to call Claude Code."
        case .dialing:      return ""
        case .onCall:       return "Double tap to mute or unmute. Shake to start over."
        }
    }
}

// MARK: - CallControlButton

private struct CallControlButton: View {
    let icon: String
    let label: String
    let background: Color
    var foreground: Color = .white
    var size: CGFloat = 72
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundColor(foreground)
                    .frame(width: size, height: size)
                    .background(background)
                    .clipShape(Circle())
            }
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
        }
    }
}

// MARK: - AudioRoutePickerView
// Wraps AVRoutePickerView — the same speaker/Bluetooth switcher the Phone
// app uses. Tapping it presents the system route sheet.

private struct AudioRoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemGreen
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

#Preview {
    ContentView()
}
