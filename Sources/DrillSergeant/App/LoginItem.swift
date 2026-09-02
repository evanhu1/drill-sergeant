import Foundation
import ServiceManagement

/// Opens Drill Sergeant at login so a reboot does not quietly uninstall the habit.
enum LoginItem {
    /// Registers once, after onboarding. Failures are logged and otherwise ignored:
    /// a missing login item is not worth interrupting anyone over.
    static func enable() {
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        do {
            try service.register()
            Log.info("Registered as a login item")
        } catch {
            Log.warn("Could not register as a login item: \(error.localizedDescription)")
        }
    }

    static func disable() {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            Log.warn("Could not remove the login item: \(error.localizedDescription)")
        }
    }
}
