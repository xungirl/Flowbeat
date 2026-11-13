import SwiftUI

@main
struct FlowbeatApp: App {
    @StateObject private var session = FocusSession()

    init() {
        PhoneSync.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
    }
}
