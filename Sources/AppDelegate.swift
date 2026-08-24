import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {

    /// Optional default server URL, so a build made for a specific Mac can call
    /// Claude without going through the magic-link/QR setup step first.
    ///
    /// The value comes from `DEFAULT_SERVER_HOST` in `Config/Local.xcconfig`,
    /// which is gitignored — this is a public repo and an ngrok domain is
    /// effectively a capability URL. When it is unset the app starts with no
    /// server and asks for one; the setup link, QR scan, and Settings all still
    /// override whatever is baked in.
    static var defaultServerURL: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "DefaultServerHost") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        return "https://\(raw)"
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let defaultURL = AppDelegate.defaultServerURL
        if !defaultURL.isEmpty {
            UserDefaults.standard.register(defaults: ["serverURL": defaultURL])
        }
        return true
    }
}
