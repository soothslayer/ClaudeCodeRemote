import Foundation

// MARK: - Errors

enum APIError: LocalizedError {
    case serverNotConfigured
    case serverUnreachable
    case timeout
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .serverNotConfigured: return "Server URL not configured"
        case .serverUnreachable:   return "Server unreachable"
        case .timeout:             return "Request timed out"
        case .serverError(let m):  return m
        }
    }
}

// MARK: - Response models

struct NewSessionResult: Codable {
    let sessionId: String
    let response: String
}

struct MessageResult: Codable {
    let sessionId: String
    let response: String
}

struct SessionInfoResult: Codable {
    let hasSession: Bool
    let sessionId: String?
    let pendingResponse: String?  // Set by server if a response arrived while iOS was backgrounded
}

struct SettingsResult: Codable {
    let workDir: String
}

// MARK: - APIService

final class APIService {

    // Loaded fresh each call so Settings changes take effect immediately
    private var baseURL: String {
        UserDefaults.standard.string(forKey: "serverURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        // No request timeout — Claude Code tasks can run for many minutes.
        // The app uses periodic audio check-ins to stay alive in the background.
        config.timeoutIntervalForRequest  = 3600  // 1 hour ceiling
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    // MARK: - Endpoints

    func newSession(prompt: String) async throws -> NewSessionResult {
        let body: [String: String] = ["prompt": prompt]
        return try await post(path: "/session/new", body: body)
    }

    func sendMessage(sessionId: String, prompt: String) async throws -> MessageResult {
        let body: [String: String] = ["session_id": sessionId, "prompt": prompt]
        return try await post(path: "/session/message", body: body)
    }

    func sessionInfo() async throws -> SessionInfoResult {
        return try await get(path: "/session/info")
    }

    func getSettings() async throws -> SettingsResult {
        return try await get(path: "/settings")
    }

    func updateSettings(workDir: String) async throws -> SettingsResult {
        let body: [String: String] = ["work_dir": workDir]
        return try await post(path: "/settings", body: body)
    }

    /// Tell the server to kill any in-flight Claude subprocess.  Used when
    /// the user long-presses to cancel — without this, the server keeps the
    /// subprocess running after the HTTP connection drops (the desired
    /// behaviour for background/timeout recovery, but not for cancellation).
    func cancelSession() async {
        struct CancelResult: Codable { let cancelled: Bool }
        _ = try? await post(path: "/session/cancel", body: [String: String]()) as CancelResult
    }

    // MARK: - HTTP helpers

    private func post<T: Decodable>(path: String, body: [String: String]) async throws -> T {
        let url = try makeURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await execute(request: request)
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        let url = try makeURL(path: path)
        let request = URLRequest(url: url)
        return try await execute(request: request)
    }

    private func makeURL(path: String) throws -> URL {
        guard !baseURL.isEmpty, let url = URL(string: baseURL + path) else {
            throw APIError.serverNotConfigured
        }
        return url
    }

    private func execute<T: Decodable>(request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost:
                throw APIError.serverUnreachable
            case .timedOut:
                throw APIError.timeout
            default:
                throw APIError.serverUnreachable
            }
        }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"] ?? "HTTP \(httpResponse.statusCode)"
            throw APIError.serverError(message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}
