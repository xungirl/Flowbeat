import SwiftUI

@main
struct FlowbeatApp: App {
    // 同一个实例也给 App Intents 用（Siri / 快捷指令开始、结束专注）
    @StateObject private var session = FocusSession.shared
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
