import SwiftUI

// MARK: - SettingsView
// Accessed via long press. Intended for a sighted caregiver to configure
// the bot server URL the first time. The blind user never needs to open this.

struct SettingsView: View {

    @AppStorage("serverURL") private var serverURL: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var urlDraft: String = ""
    @State private var showingConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://your-ngrok-url.ngrok.io", text: $urlDraft)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Bot Server URL")
                } footer: {
                    Text("Enter the public URL of the Claude Code bot server running on your computer. Get this URL by running setup.sh in the bot/ directory.")
                        .font(.footnote)
                }

                Section {
                    Button("Save") {
                        serverURL = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        showingConfirmation = true
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
            .onAppear {
                urlDraft = serverURL
            }
        }
    }
}

#Preview {
    SettingsView()
}
