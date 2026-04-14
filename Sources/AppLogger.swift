import Foundation
import os

// MARK: - AppLogger
// Lightweight in-process log store. Writes to os.Logger (visible in Console.app
// and Xcode) AND keeps the last 300 entries in memory so they can be read from
// the in-app log viewer in Settings without needing Xcode attached.

@MainActor
final class AppLogger: ObservableObject {

    static let shared = AppLogger()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let tag: String
        let message: String

        var formatted: String {
            let t = DateFormatter.logTime.string(from: timestamp)
            return "[\(t)] \(tag): \(message)"
        }
    }

    @Published private(set) var entries: [Entry] = []

    private let osLog = Logger(subsystem: "com.claudecoderemote.app", category: "main")
    private let maxEntries = 300

    private init() {}

    func log(_ message: String, tag: String = "APP") {
        osLog.info("[\(tag)] \(message)")
        let entry = Entry(timestamp: Date(), tag: tag, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    var text: String {
        entries.map(\.formatted).joined(separator: "\n")
    }
}

private extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
