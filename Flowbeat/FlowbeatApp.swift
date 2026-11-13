import SwiftUI

@main
struct FlowbeatApp: App {
    @StateObject private var session = FocusSession()
    @StateObject private var permissions = PermissionCenter()

    init() {
        PhoneSync.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environmentObject(permissions)
        }
    }
}
