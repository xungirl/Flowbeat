import FlowbeatCore
import FlowbeatPhoneUI
import SwiftUI
import WatchConnectivity

/// iPhone 伴侣 app：接收手表传来的专注存档，画专注时间线。
@main
struct FlowbeatPhoneApp: App {
    @StateObject private var store = SessionStore()
    @StateObject private var receiver = WatchReceiver()

    var body: some Scene {
        WindowGroup {
            SessionListView()
                .environmentObject(store)
                .environmentObject(receiver)
                .onAppear { receiver.start(store: store) }
        }
    }
}

// MARK: - 存档

@MainActor
final class SessionStore: ObservableObject {
    struct Item: Identifiable, Hashable {
        let id: URL
        let record: SessionRecord
        let isSample: Bool

        static func == (a: Item, b: Item) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    @Published private(set) var items: [Item] = []

    nonisolated static var archive: SessionArchive {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return SessionArchive(directory: docs.appendingPathComponent("sessions", isDirectory: true))
    }

    init() { reload() }

    /// 读存档目录；一条都没有时放一条打包进 app 的示例（手表模拟器演示模式生成），并标明是示例
    func reload() {
        var list = Self.archive.loadAll().map { Item(id: $0.url, record: $0.record, isSample: false) }
        if list.isEmpty, let url = Bundle.main.url(forResource: "sample-session", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let r = try? FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: data) {
            list = [Item(id: url, record: r, isSample: true)]
        }
        items = list
    }
}

// MARK: - WatchConnectivity

final class WatchReceiver: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var status = String(localized: "Connecting to Apple Watch…")
    @Published private(set) var received = 0
    private weak var store: SessionStore?

    func start(store: SessionStore) {
        self.store = store
        guard WCSession.isSupported() else {
            status = String(localized: "This device doesn't support Apple Watch connectivity.")
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let text: String
        if let error {
            text = String(localized: "Connection failed: \(error.localizedDescription)")
        } else if !session.isPaired {
            text = String(localized: "No paired Apple Watch")
        } else if !session.isWatchAppInstalled {
            text = String(localized: "Flowbeat isn't installed on your Apple Watch yet")
        } else {
            text = String(localized: "Apple Watch connected · sessions sync when you end a focus session")
        }
        DispatchQueue.main.async { self.status = text }
    }

    /// 系统给的临时文件在这个回调返回后就会被删，所以这里同步拷进存档目录
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let name = file.metadata?["name"] as? String
        do {
            try SessionStore.archive.importFile(at: file.fileURL, name: name)
            DispatchQueue.main.async {
                self.received += 1
                self.store?.reload()
            }
        } catch {
            DispatchQueue.main.async { self.status = String(localized: "A received session couldn't be read") }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// 换了一块手表：重新激活，才能收到新手表的数据
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}

// MARK: - 页面

struct SessionListView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var receiver: WatchReceiver

    @State private var path: [SessionStore.Item] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(store.items) { item in
                        NavigationLink(value: item) {
                            SessionRow(record: item.record, isSample: item.isSample)
                        }
                    }
                } footer: {
                    Label(receiver.status, systemImage: "applewatch")
                }
            }
            .navigationTitle(Text(verbatim: "Flowbeat"))
            .navigationDestination(for: SessionStore.Item.self) { item in
                ScrollView {
                    SessionDetailContent(record: item.record, isSample: item.isSample).padding()
                }
                .navigationTitle(item.record.samples.first.map { $0.t.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Session"))
                .navigationBarTitleDisplayMode(.inline)
            }
            .refreshable { store.reload() }
        }
        #if targetEnvironment(simulator)
        // -openFirst：直接打开第一条（CI 上截详情页用）
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-openFirst"), let first = store.items.first { path = [first] }
        }
        #endif
    }
}
