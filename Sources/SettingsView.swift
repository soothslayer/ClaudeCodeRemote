import SwiftUI
import VisionKit
import UIKit

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

#Preview {
    SettingsView()
}
