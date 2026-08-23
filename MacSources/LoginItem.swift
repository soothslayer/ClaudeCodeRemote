import Foundation
import ServiceManagement

/// Launch-at-login, via the modern SMAppService registration.
///
/// This replaces the hand-written LaunchAgent plist that setup.sh installs for
/// the source-tree deployment: the .app registers itself, so there is no plist
/// to keep in sync with the install location.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
