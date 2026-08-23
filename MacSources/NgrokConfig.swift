import Foundation

/// Reads and writes the shared config.json that the Python server also uses.
///
/// Only the keys this app owns are touched — `work_dir` and anything else the
/// server writes is preserved on save.
enum NgrokConfig {

    static func load() -> [String: Any] {
        guard
            let data = try? Data(contentsOf: BundleLayout.configFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static var staticDomain: String {
        (load()["ngrok_static_domain"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func setStaticDomain(_ domain: String) throws {
        var config = load()
        config["ngrok_static_domain"] = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if config["work_dir"] == nil {
            config["work_dir"] = "~/git/buck"
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: BundleLayout.configFile, options: .atomic)
    }

    /// Hands the authtoken to `ngrok config add-authtoken`, which stores it in
    /// ngrok's own config file. The token never touches our config.json.
    static func saveAuthToken(_ token: String) -> Result<Void, NgrokError> {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(()) }
        guard let binary = BundleLayout.ngrok else {
            return .failure(.binaryMissing)
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["config", "add-authtoken", trimmed]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "ngrok reported an error."
            return .failure(.rejected(message))
        }
        return .success(())
    }

    enum NgrokError: LocalizedError {
        case binaryMissing
        case launchFailed(String)
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "The ngrok binary is missing from the app bundle."
            case .launchFailed(let detail):
                return "Could not run ngrok: \(detail)"
            case .rejected(let detail):
                return detail
            }
        }
    }
}
