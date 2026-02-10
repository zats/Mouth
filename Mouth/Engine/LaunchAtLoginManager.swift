import Foundation
import ServiceManagement

enum LaunchAtLoginManager {
    static let defaultsKey = "mouth.launch_at_login"

    static func applySavedSetting() {
        setEnabled(UserDefaults.standard.bool(forKey: defaultsKey))
    }

    static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13, *) else { return }
        let service = SMAppService.mainApp
        if enabled {
            try? service.register()
        } else {
            try? service.unregister()
        }
    }
}

