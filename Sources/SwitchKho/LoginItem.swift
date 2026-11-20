import ServiceManagement

/// Switch Kho as a login item, so the guard is there whenever apps run from the Kho.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    static var needsApproval: Bool { status == .requiresApproval }

    static func setEnabled(_ on: Bool) throws {
        if on {
            if status != .enabled { try SMAppService.mainApp.register() }
        } else if status == .enabled || status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
