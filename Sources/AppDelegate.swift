import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {

    /// Default server URL baked into the app so a fresh install can call Claude
    /// without going through the magic-link/QR setup step first. Users can still
    /// override it via the setup link, QR scan, or Settings.
    static let defaultServerURL = "https://unspatial-triston-companionable.ngrok-free.dev"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UserDefaults.standard.register(defaults: [
            "serverURL": AppDelegate.defaultServerURL
        ])
        return true
    }
}
