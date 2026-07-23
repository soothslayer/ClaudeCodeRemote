import Foundation

// MARK: - RealtimeClient
// WebSocket connection to the bot server's /ws endpoint — the full-duplex
// transport. JSON messages both ways (protocol v1):
//   up:   start / user_text / interrupt / ping
//   down: session / assistant_delta / tool_activity / turn_done / status /
//         error / pong
// Auto-reconnects with backoff; on reconnect re-sends start(resume:true) so
// the server re-attaches the persistent Claude session and delivers any
// response that arrived while we were offline.

enum ServerEvent {
    case connected(reconnect: Bool)
    case disconnected
    case session(id: String)
    case assistantDelta(String)
    case toolActivity(String)
    case turnDone(String)
    case status(working: Bool)
    case serverError(String)
}

@MainActor
final class RealtimeClient: NSObject, ObservableObject {

    @Published private(set) var isConnected = false

    /// Delivered on the main actor.
    var onEvent: ((ServerEvent) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var generation = 0            // invalidates callbacks from old sockets
    private var everConnected = false
    private var shouldRun = false
    private var hasStartedSession = false
    private var lastResumeFlag = true

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    // MARK: - Public API

    /// Opens the socket and keeps it open (reconnecting) until disconnect().
    /// Returns true once connected, false if the first attempt times out.
    func connect() async -> Bool {
        shouldRun = true
        return await openSocket()
    }

    func disconnect() {
        shouldRun = false
        generation += 1
        pingTask?.cancel()
        reconnectTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    func startSession(resume: Bool) {
        hasStartedSession = true
        lastResumeFlag = resume
        send(["type": "start", "resume": resume])
    }

    func sendUserText(_ text: String) {
        send(["type": "user_text", "text": text])
    }

    func sendInterrupt() {
        send(["type": "interrupt"])
    }

    private func send(_ payload: [String: Any]) {
        guard let ws = task,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { error in
            if let error {
                Task { @MainActor in
                    AppLogger.shared.log("WS send failed: \(error.localizedDescription)", tag: "WS")
                }
            }
        }
    }

    // MARK: - Socket lifecycle

    private var wsURL: URL? {
        let raw = UserDefaults.standard.string(forKey: "serverURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, var components = URLComponents(string: raw) else { return nil }
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        components.path = "/ws"
        return components.url
    }

    private func openSocket() async -> Bool {
        guard let url = wsURL else {
            onEvent?(.serverError("Server URL is not configured."))
            return false
        }
        generation += 1
        let gen = generation

        task?.cancel(with: .goingAway, reason: nil)
        let ws = urlSession.webSocketTask(with: url)
        task = ws
        ws.resume()

        // Probe with a ping — resume() alone doesn't tell us the socket is up.
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            ws.sendPing { error in
                cont.resume(returning: error == nil)
            }
        }
        guard gen == generation else { return false }
        guard ok else {
            AppLogger.shared.log("WS connect failed", tag: "WS")
            scheduleReconnect()
            return false
        }

        let isReconnect = everConnected
        everConnected = true
        isConnected = true
        AppLogger.shared.log("WS connected (reconnect=\(isReconnect))", tag: "WS")
        receiveLoop(ws, gen: gen)
        startPinging(ws, gen: gen)

        // Re-attach the session after a drop so pending responses flow in.
        if isReconnect && hasStartedSession {
            startSession(resume: true)
        }
        onEvent?(.connected(reconnect: isReconnect))
        return true
    }

    private func receiveLoop(_ ws: URLSessionWebSocketTask, gen: Int) {
        ws.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        self.handle(text)
                    }
                    self.receiveLoop(ws, gen: gen)
                case .failure(let error):
                    AppLogger.shared.log("WS receive error: \(error.localizedDescription)", tag: "WS")
                    self.socketDropped()
                }
            }
        }
    }

    private func startPinging(_ ws: URLSessionWebSocketTask, gen: Int) {
        pingTask?.cancel()
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                ws.sendPing { error in
                    if error != nil {
                        Task { @MainActor [weak self] in
                            guard let self, gen == self.generation else { return }
                            self.socketDropped()
                        }
                    }
                }
            }
        }
    }

    private func socketDropped() {
        guard isConnected else { return }
        isConnected = false
        pingTask?.cancel()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        onEvent?(.disconnected)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            var delay: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                guard let self, self.shouldRun, !self.isConnected, !Task.isCancelled else { return }
                AppLogger.shared.log("WS reconnecting…", tag: "WS")
                if await self.openSocket() { return }
                delay = min(delay * 2, 15_000_000_000)
            }
        }
    }

    // MARK: - Message decoding

    private struct WireEvent: Decodable {
        let type: String
        let text: String?
        let message: String?
        let sessionId: String?
        let state: String?
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let evt = try? decoder.decode(WireEvent.self, from: data) else { return }

        switch evt.type {
        case "session":
            if let id = evt.sessionId, !id.isEmpty { onEvent?(.session(id: id)) }
        case "assistant_delta":
            if let text = evt.text { onEvent?(.assistantDelta(text)) }
        case "tool_activity":
            if let text = evt.text { onEvent?(.toolActivity(text)) }
        case "turn_done":
            onEvent?(.turnDone(evt.text ?? ""))
        case "status":
            onEvent?(.status(working: evt.state == "working"))
        case "error":
            onEvent?(.serverError(evt.message ?? "Unknown server error"))
        default:
            break   // pong etc.
        }
    }
}
