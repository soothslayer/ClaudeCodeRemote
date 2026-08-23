import Foundation

/// Resolves the pieces of the server that ship inside the .app bundle.
///
/// Bundle layout produced by `mac/build_python_runtime.sh`:
///
///     Contents/Resources/python/bin/python3   relocatable CPython + deps
///     Contents/Resources/bot/                 server.py, serve_headless.py, …
///     Contents/Resources/bin/ngrok            embedded tunnel binary
///     Contents/Resources/computer_use_mcp.py  uncompiled copy for paths.mcp_sidecar()
///
/// A developer running from Xcode can point at a source checkout instead by
/// setting the `botDirOverride` / `pythonOverride` user defaults.
enum BundleLayout {

    static var resources: URL {
        Bundle.main.resourceURL ?? Bundle.main.bundleURL
    }

    /// The Python interpreter that runs the server.
    static var interpreter: URL? {
        if let override = UserDefaults.standard.string(forKey: "pythonOverride") {
            return URL(fileURLWithPath: override)
        }
        let embedded = resources.appendingPathComponent("python/bin/python3")
        return FileManager.default.isExecutableFile(atPath: embedded.path) ? embedded : nil
    }

    /// Directory holding serve_headless.py and the rest of the server.
    static var botDirectory: URL? {
        if let override = UserDefaults.standard.string(forKey: "botDirOverride") {
            return URL(fileURLWithPath: override)
        }
        let embedded = resources.appendingPathComponent("bot")
        return FileManager.default.fileExists(atPath: embedded.appendingPathComponent("serve_headless.py").path)
            ? embedded : nil
    }

    static var entrypoint: URL? {
        botDirectory?.appendingPathComponent("serve_headless.py")
    }

    /// The embedded ngrok binary, used for `ngrok config add-authtoken`.
    static var ngrok: URL? {
        let embedded = resources.appendingPathComponent("bin/ngrok")
        if FileManager.default.isExecutableFile(atPath: embedded.path) { return embedded }
        for fallback in ["/opt/homebrew/bin/ngrok", "/usr/local/bin/ngrok"] {
            if FileManager.default.isExecutableFile(atPath: fallback) {
                return URL(fileURLWithPath: fallback)
            }
        }
        return nil
    }

    /// ~/Library/Application Support/ClaudeCodeRemote — mirrors bot/paths.py.
    static var configDirectory: URL {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeCodeRemote")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var configFile: URL { configDirectory.appendingPathComponent("config.json") }

    /// ~/Library/Logs/ClaudeCodeRemote — mirrors bot/paths.py.
    static var logDirectory: URL {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeCodeRemote")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A PATH the child process can find `claude`, `node`, and friends on.
    ///
    /// A GUI app inherits a bare PATH from launchd, so the well-known install
    /// locations are spliced in explicitly — the same list bot/paths.py walks.
    static var childPATH: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        return dirs.joined(separator: ":")
    }
}
