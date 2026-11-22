import FlowbeatCore
import FlowbeatPhoneData
import SwiftData
import SwiftUI

/// iPhone 端：手表传来的每次专注存进 SwiftData 数据库（开了 iCloud 就同步到用户自己的 iCloud），
/// 首页看今天 / 7 天 / 30 天，记录页看每一次的时间线、写备注、导出，设置页改每日目标（同步到手表）。
@main
struct FlowbeatPhoneApp: App {
    private let store: (container: ModelContainer, location: FlowbeatStore.Location)
    @StateObject private var watch = WatchLink()

    init() {
        #if targetEnvironment(simulator)
        // -demoData：内存数据库 + 一个月的示例记录（App Store 截图用，不写盘）
        if ProcessInfo.processInfo.arguments.contains("-demoData"),
           let c = try? FlowbeatStore.makeContainer(.inMemory) {
            DemoData.seed(c.mainContext)
            store = (c, .inMemory)
            return
        }
        #endif
        var id = Bundle.main.object(forInfoDictionaryKey: "FlowbeatCloudKitContainer") as? String
        #if targetEnvironment(simulator)
        // 没签名的模拟器构建（CI、命令行）没有 iCloud entitlement，CloudKit 会在后台线程直接崩（try 接不住）。
        // 模拟器默认只存本机；在 Xcode 里签名运行、想测 iCloud 时加启动参数 -iCloud。
        if !ProcessInfo.processInfo.arguments.contains("-iCloud") { id = nil }
        #endif
        store = FlowbeatStore.makeAppContainer(cloudKitContainer: id)
        Self.migrateLegacyArchive(into: store.container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView(storageLocation: store.location)
                .environmentObject(watch)
                .onAppear { watch.start(container: store.container) }
        }
        .modelContainer(store.container)
    }

    /// 旧版把存档放在 Documents/sessions/*.json：导进数据库后删掉文件
    @MainActor private static func migrateLegacyArchive(into context: ModelContext) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        SessionLibrary.importLegacyArchive(directory: docs.appendingPathComponent("sessions", isDirectory: true),
                                           into: context, raw: PhoneStorage.raw)
        _ = try? SessionLibrary.removeDuplicates(in: context)
    }
}

struct RootView: View {
    let storageLocation: FlowbeatStore.Location
    @AppStorage("tab") private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            OverviewView()
                .tabItem { Label("Today", systemImage: "circle.dashed") }
                .tag(0)
            SessionsView()
                .tabItem { Label("Sessions", systemImage: "list.bullet") }
                .tag(1)
            PhoneSettingsView(storageLocation: storageLocation)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        .tint(.mint)
    }
}

/// 带心率的原始存档目录（只在本机，不进 iCloud、不进云备份），见 FlowbeatPhoneData.RawArchive
enum PhoneStorage {
    static let raw: RawArchive = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RawArchive(directory: base.appendingPathComponent("RawSessions", isDirectory: true))
    }()
}

/// 打包进 app 的示例（手表模拟器演示模式生成的 4 分钟），只用来展示，不写进数据库
enum SampleSession {
    static let record: SessionRecord? = {
        guard let url = Bundle.main.url(forResource: "sample-session", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: data)
    }()
}
