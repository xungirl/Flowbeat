import SwiftUI

@main
struct FocusWatchApp: App {
    @StateObject private var session = FocusSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
    }
}
