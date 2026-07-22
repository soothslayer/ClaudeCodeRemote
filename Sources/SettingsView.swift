import SwiftUI
import VisionKit
import UIKit
import AVFoundation

// MARK: - SettingsView
// Accessed via long press. Intended for a sighted caregiver to configure
// the bot server URL the first time. The blind user never needs to open this.

struct SettingsView: View {

    @AppStorage("serverURL") private var serverURL: String = ""
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var logger = AppLogger.shared
    @State private var urlDraft: String = ""
    @State private var workDirDraft: String = ""
    @State private var showingScanner = false
    @State private var showingConfirmation = false
    @State private var showingLogs = false
    @State private var isSavingWorkDir = false

    private let apiService = APIService()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://xxxx.ngrok-free.app", text: $urlDraft)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        Button {
                            showingScanner = true
                        } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        }
                    }
                } header: {
                    Text("Bot Server URL")
                } footer: {
                    Text("Paste the ngrok URL, or scan the QR code from http://localhost:8080/qr on the server computer.")
                        .font(.footnote)
                }

                Section {
                    TextField("~/git/buck", text: $workDirDraft)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .overlay(alignment: .trailing) {
                            if isSavingWorkDir {
                                ProgressView().padding(.trailing, 8)
                            }
                        }
                } header: {
                    Text("Working Directory")
                } footer: {
                    Text("The folder Claude Code runs in on the server. Use ~ for your home directory.")
                        .font(.footnote)
                }

                Section {
                    Button("Save") {
                        serverURL = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        saveWorkDir()
                    }
                    .disabled(urlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section {
                    NavigationLink {
                        VoicePickerView()
                    } label: {
                        HStack {
                            Text("Voice")
                            Spacer()
                            Text(currentVoiceLabel)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("Speech")
                } footer: {
                    Text("Tap to pick a voice. For dramatically better quality, download Premium or Enhanced English voices in the iPhone's Settings → Accessibility → Spoken Content → Voices → English.")
                        .font(.footnote)
                }

                Section {
                    Button("Clear Session", role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: "lastClaudeSessionId")
                    }
                } header: {
                    Text("Session")
                } footer: {
                    Text("Clearing the session means the next voice request will start a brand new Claude Code conversation.")
                }

                Section {
                    Button("View Logs (\(logger.entries.count))") {
                        showingLogs = true
                    }
                    Button("Clear Logs", role: .destructive) {
                        AppLogger.shared.clear()
                    }
                } header: {
                    Text("Diagnostics")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Saved", isPresented: $showingConfirmation) {
                Button("OK") { dismiss() }
            } message: {
                Text("Server URL has been saved. Return to the main screen and tap anywhere to start.")
            }
            .sheet(isPresented: $showingLogs) {
                LogViewer()
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerView { url in
                    urlDraft = url
                    showingScanner = false
                }
                .ignoresSafeArea()
            }
            .onAppear {
                urlDraft = serverURL
                fetchWorkDir()
            }
        }
    }

    // MARK: - Helpers

    /// Label shown next to "Voice" — the currently picked voice's name +
    /// quality tag, or "Auto (best available)" if the user hasn't chosen one.
    private var currentVoiceLabel: String {
        if let id = UserDefaults.standard.string(forKey: VoiceManager.selectedVoiceIdKey),
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            return "\(voice.name) (\(qualityTag(voice.quality)))"
        }
        if let auto = VoiceManager.bestEnglishVoice() {
            return "Auto — \(auto.name)"
        }
        return "Auto"
    }

    private func qualityTag(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Default"
        }
    }

    private func fetchWorkDir() {
        guard !serverURL.isEmpty else { return }
        Task {
            if let result = try? await apiService.getSettings() {
                workDirDraft = result.workDir
            }
        }
    }

    private func saveWorkDir() {
        let dir = workDirDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty, !serverURL.isEmpty else {
            showingConfirmation = true
            return
        }
        isSavingWorkDir = true
        Task {
            _ = try? await apiService.updateSettings(workDir: dir)
            await MainActor.run {
                isSavingWorkDir = false
                showingConfirmation = true
            }
        }
    }
}

// MARK: - LogViewer

struct LogViewer: View {
    @ObservedObject private var logger = AppLogger.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logger.entries) { entry in
                            Text(entry.formatted)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(color(for: entry.tag))
                                .textSelection(.enabled)
                                .id(entry.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: logger.entries.count) { _ in
                    if let last = logger.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Copy") {
                        UIPasteboard.general.string = logger.text
                    }
                }
            }
            .background(Color.black)
        }
    }

    private func color(for tag: String) -> Color {
        switch tag {
        case "TTS":   return .cyan
        case "PERM":  return .yellow
        case "INIT":  return .green
        case "GREET": return .mint
        case "TAP":   return .orange
        default:      return .white
        }
    }
}

// MARK: - VoicePickerView

/// Lists every installed English voice, grouped by quality (Premium first).
/// Tap a row to hear a sample; the check-marked row is the current selection.
/// "Automatic" at the top means: use the best voice installed right now, and
/// re-pick automatically if the user installs a better one later.
struct VoicePickerView: View {

    @AppStorage(VoiceManager.selectedVoiceIdKey) private var selectedId: String = ""
    @State private var voices: [AVSpeechSynthesisVoice] = []
    /// A short sentence with pauses so both the timbre and the prosody are audible.
    private let sample = "Hi. I'm the voice you'll hear when Claude Code speaks."
    /// Shared synthesizer instance used to play samples — the picker outlives
    /// individual rows so this stays alive between taps.
    private let sampleSynth = AVSpeechSynthesizer()

    var body: some View {
        Form {
            Section {
                voiceRow(
                    title: "Automatic",
                    subtitle: VoiceManager.bestEnglishVoice().map { "Currently: \($0.name)" } ?? "No English voices installed",
                    isSelected: selectedId.isEmpty,
                    onSelect: {
                        selectedId = ""
                        if let auto = VoiceManager.bestEnglishVoice() {
                            playSample(auto)
                        }
                    }
                )
            } footer: {
                Text("Picks the best voice currently installed. Upgrades automatically when you install a better one from Settings → Accessibility.")
                    .font(.footnote)
            }

            ForEach(qualityGroups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.voices, id: \.identifier) { voice in
                        voiceRow(
                            title: voice.name,
                            subtitle: voice.language,
                            isSelected: selectedId == voice.identifier,
                            onSelect: {
                                selectedId = voice.identifier
                                playSample(voice)
                            }
                        )
                    }
                }
            }

            Section {
                Link(destination: URL(string: "App-Prefs:ACCESSIBILITY&path=SPEECH")!) {
                    Label("Install more voices…", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("Opens the iPhone's Spoken Content settings so you can download Premium and Enhanced voices. They're free but ~100–200 MB each.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { voices = VoiceManager.availableEnglishVoices() }
        .onDisappear { sampleSynth.stopSpeaking(at: .immediate) }
    }

    // MARK: Row

    private func voiceRow(title: String, subtitle: String, isSelected: Bool, onSelect: @escaping () -> Void) -> some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(.primary)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
    }

    // MARK: Grouping

    private struct VoiceGroup {
        let title: String
        let voices: [AVSpeechSynthesisVoice]
    }

    private var qualityGroups: [VoiceGroup] {
        let premium  = voices.filter { $0.quality == .premium  }
        let enhanced = voices.filter { $0.quality == .enhanced }
        let standard = voices.filter { $0.quality != .premium && $0.quality != .enhanced }
        var groups: [VoiceGroup] = []
        if !premium.isEmpty  { groups.append(.init(title: "Premium",  voices: premium))  }
        if !enhanced.isEmpty { groups.append(.init(title: "Enhanced", voices: enhanced)) }
        if !standard.isEmpty { groups.append(.init(title: "Standard", voices: standard)) }
        return groups
    }

    // MARK: Sample playback

    private func playSample(_ voice: AVSpeechSynthesisVoice) {
        if sampleSynth.isSpeaking { sampleSynth.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: sample)
        utterance.voice = voice
        utterance.rate = 0.5
        sampleSynth.speak(utterance)
    }
}

#Preview {
    SettingsView()
}
