import SwiftUI
import AppKit

/// Menu-bar host for the Claude Code Remote server.
///
/// The app itself is a thin Swift shell: it owns the status item and the two
/// setup windows, and supervises `bot/serve_headless.py` — the FastAPI server
/// plus the ngrok tunnel — as a child process. See ServerController.
@main
struct ClaudeCodeRemoteServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = ServerController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(controller)
        } label: {
            // ☁ alone while connecting, ☁✓ once the tunnel is up — legible at a
            // glance without opening the menu.
            Text(menuBarTitle)
        }

        Window("ngrok Setup", id: "ngrok-settings") {
            NgrokSettingsView().environmentObject(controller)
        }
        .windowResizability(.contentSize)

        Window("Server Log", id: "server-log") {
            ServerLogView().environmentObject(controller)
        }
    }

    private var menuBarTitle: String {
        switch controller.state {
        case .running: return "☁✓"
        case .failed:  return "☁!"
        default:       return "☁"
        }
    }
}

/// The app has no main window — closing the log or setup window must not quit it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
