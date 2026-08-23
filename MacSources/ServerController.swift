import Foundation
import AppKit
import Combine

/// Supervises the embedded Python server as a child process and surfaces its
/// state to the menu bar.
///
/// The child is `python3 bot/serve_headless.py`, which prints one JSON object
/// per line describing what it is doing (see serve_headless.py for the
/// protocol).  Lines that don't parse are treated as plain log output.
@MainActor
final class ServerController: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        case waitingForTunnel
        case running(url: String)
        case failed(reason: String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var logLines: [String] = []

    /// Public ngrok URL, when the tunnel is up.
    var publicURL: String? {
        if case .running(let url) = state { return url }
        return nil
    }

    var magicLink: String? {
        publicURL.map { "clauderemote://setup?url=\($0)" }
    }

    /// Defaults to 8080; override with `defaults write com.claudecoderemote.server
    /// serverPort <n>` to run a second instance alongside an existing one.
    let port: Int = {
        let configured = UserDefaults.standard.integer(forKey: "serverPort")
        return (1...65535).contains(configured) ? configured : 8080
    }()

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var intentionalStop = false

    private let maxLogLines = 500

    // MARK: - Lifecycle

    init() {
        // The app is the server: there is nothing to do but run it.
        start()
        // A menu-bar app with no windows never sees applicationWillTerminate
        // through a scene, so hook the notification directly — otherwise
        // uvicorn and ngrok outlive the Quit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func start() {
        guard process == nil else { return }

        guard let interpreter = BundleLayout.interpreter else {
            state = .failed(reason: "Embedded Python runtime is missing from the app bundle.")
            return
        }
        guard let entrypoint = BundleLayout.entrypoint, let botDir = BundleLayout.botDirectory else {
            state = .failed(reason: "Server sources are missing from the app bundle.")
            return
        }

        intentionalStop = false
        state = .starting
        stdoutBuffer = Data()

        let proc = Process()
        proc.executableURL = interpreter
        proc.arguments = [entrypoint.path]
        proc.currentDirectoryURL = botDir

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BundleLayout.childPATH
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["CLAUDE_REMOTE_PORT"] = String(port)
        proc.environment = env

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consumeStdout(chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor in
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    self?.appendLog(String(line))
                }
            }
        }

        proc.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.handleTermination(status: finished.terminationStatus) }
        }

        do {
            try proc.run()
            process = proc
            stdoutPipe = out
            stderrPipe = err
            appendLog("Server process started (pid \(proc.processIdentifier)).")
        } catch {
            state = .failed(reason: "Could not launch the server: \(error.localizedDescription)")
            appendLog("Launch failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        intentionalStop = true
        teardown()
        state = .stopped
    }

    func restart() {
        appendLog("Restarting server…")
        intentionalStop = true
        teardown()
        // Give the port a moment to free up before rebinding.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.start()
        }
    }

    private func teardown() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
            // SIGTERM lets serve_headless.py stop ngrok cleanly; escalate if it hangs.
            let deadline = Date().addingTimeInterval(5)
            while proc.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func handleTermination(status: Int32) {
        process = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil

        guard !intentionalStop else { return }
        appendLog("Server exited with status \(status).")
        state = .failed(reason: "The server stopped unexpectedly (status \(status)).")
    }

    // MARK: - Child output

    private func consumeStdout(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let newline = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            handle(line: line)
        }
    }

    private func handle(line: String) {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let event = object["event"] as? String
        else {
            appendLog(line)
            return
        }

        switch event {
        case "starting":
            state = .starting
        case "server_ready":
            if case .running = state {} else { state = .waitingForTunnel }
            appendLog("Server listening on port \(port).")
        case "ngrok_url":
            if let url = object["url"] as? String, !url.isEmpty {
                state = .running(url: url)
                appendLog("Tunnel up: \(url)")
            } else {
                state = .waitingForTunnel
                appendLog("Tunnel down — reconnecting.")
            }
        case "fatal":
            let reason = object["message"] as? String ?? "unknown error"
            state = .failed(reason: reason)
            appendLog("FATAL: \(reason)")
        case "log":
            appendLog(object["message"] as? String ?? line)
        default:
            appendLog(line)
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    // MARK: - Menu actions

    func copyMagicLink() -> Bool {
        guard let link = magicLink else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        return true
    }

    func openQRPage() {
        NSWorkspace.shared.open(URL(string: "http://localhost:\(port)/qr")!)
    }

    func openActivityWindow() {
        NSWorkspace.shared.open(URL(string: "http://localhost:\(port)/activity")!)
    }

    func revealLogs() {
        NSWorkspace.shared.open(BundleLayout.logDirectory)
    }
}
