import SwiftUI

@main
struct FlowbeatApp: App {
    @StateObject private var session = FocusSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
    }
}
