import ServiceManagement

/// Wraps SMAppService so Breadcrumbs can register itself to launch at login —
/// the modern replacement for a ~/Library/LaunchAgents plist or a manual drag into
/// System Settings > Login Items. Requires the running app to be code-signed
/// (ad-hoc signing, as scripts/build_app.sh does, is sufficient).
enum LoginItemManager {
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    Log.write("Breadcrumbs is registered to launch at login but needs approval — opening System Settings.\n")
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("Login item registration failed: \(error)\n")
        }
    }
}
