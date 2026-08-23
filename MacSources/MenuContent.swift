import SwiftUI
import AppKit

/// The menu that drops down from the status item.
///
/// Everything a sighted caregiver needs to get the phone talking to this Mac is
/// one click deep, mirroring the old rumps menu in menu_bar.py.
struct MenuContent: View {
    @EnvironmentObject private var controller: ServerController
    @Environment(\.openWindow) private var openWindow

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var copyConfirmation = false

    var body: some View {
        Text(statusLine)

        Divider()

        Button(copyConfirmation ? "Magic Link Copied ✓" : "Copy Magic Link") {
            if controller.copyMagicLink() {
                copyConfirmation = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    copyConfirmation = false
                }
            }
        }
        .disabled(controller.publicURL == nil)

        Button("Open QR Page") { controller.openQRPage() }
        Button("Open Activity Window") { controller.openActivityWindow() }

        Divider()

        Button("Configure ngrok…") {
            openWindow(id: "ngrok-settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Show Log…") {
            openWindow(id: "server-log")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Reveal Logs in Finder") { controller.revealLogs() }

        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, newValue in
                do {
                    try LoginItem.setEnabled(newValue)
                } catch {
                    // Revert the toggle so it never lies about the real state.
                    launchAtLogin = LoginItem.isEnabled
                }
            }

        Divider()

        Button("Restart Server") { controller.restart() }
        Button("Quit") {
            controller.stop()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch controller.state {
        case .stopped:
            return "Status: stopped"
        case .starting:
            return "Status: starting…"
        case .waitingForTunnel:
            return "Status: waiting for ngrok…"
        case .running(let url):
            return "Status: running ✓  \(url)"
        case .failed(let reason):
            return "Status: error — \(reason)"
        }
    }
}
