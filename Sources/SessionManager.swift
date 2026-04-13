import Foundation

// Persists the current Claude Code session ID across app launches.
final class SessionManager {

    private let defaults = UserDefaults.standard
    private let sessionIdKey = "lastClaudeSessionId"

    var hasSession: Bool {
        lastSessionId != nil
    }

    var lastSessionId: String? {
        defaults.string(forKey: sessionIdKey)
    }

    func saveSession(id: String) {
        defaults.set(id, forKey: sessionIdKey)
    }

    func clearSession() {
        defaults.removeObject(forKey: sessionIdKey)
    }
}
