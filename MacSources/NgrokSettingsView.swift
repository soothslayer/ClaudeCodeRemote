import SwiftUI

/// Authtoken + static-domain setup, the two things ngrok needs before the
/// magic link stays valid across restarts.
struct NgrokSettingsView: View {
    @EnvironmentObject private var controller: ServerController
    @Environment(\.dismiss) private var dismiss

    @State private var authToken = ""
    @State private var staticDomain = NgrokConfig.staticDomain
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ngrok Setup")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Authtoken")
                    .font(.headline)
                SecureField("Paste your ngrok authtoken", text: $authToken)
                    .textFieldStyle(.roundedBorder)
                Text("From dashboard.ngrok.com → Your Authtoken. Leave blank to keep the one already saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Static domain")
                    .font(.headline)
                TextField("your-name.ngrok-free.app", text: $staticDomain)
                    .textFieldStyle(.roundedBorder)
                Text("Claim a free one at dashboard.ngrok.com → Domains. Without it the URL changes on every restart and the phone needs re-pairing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save & Restart Tunnel") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 400)
    }

    private func save() {
        if !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if case .failure(let error) = NgrokConfig.saveAuthToken(authToken) {
                message = error.localizedDescription
                messageIsError = true
                return
            }
            authToken = ""
        }

        do {
            try NgrokConfig.setStaticDomain(staticDomain)
        } catch {
            message = "Could not save the domain: \(error.localizedDescription)"
            messageIsError = true
            return
        }

        // The supervisor picks up a changed domain by relaunching ngrok, which
        // the server does on restart.
        controller.restart()
        dismiss()
    }
}
