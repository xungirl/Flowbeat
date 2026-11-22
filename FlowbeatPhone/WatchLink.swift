import FlowbeatCore
import FlowbeatPhoneData
import SwiftData
import SwiftUI
import WatchConnectivity

/// iPhone ↔ 手表：收存档文件写进数据库，双向同步每日目标。
@MainActor
final class WatchLink: NSObject, ObservableObject {
    enum Status: Equatable {
        case unsupported
        case connecting
        case notPaired
        case appNotInstalled
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .connecting
    @Published private(set) var lastReceived: Date?
    @Published private(set) var receivedThisLaunch = 0
    @Published private(set) var lastError: String?

    private var container: ModelContainer?
    private let defaults = UserDefaults.standard

    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        guard WCSession.isSupported() else {
            status = .unsupported
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// 设置页改了每日目标
    func dailyGoalChanged(to minutes: Int) {
        let s = SharedSettings(dailyGoalMinutes: minutes, updatedAt: Date())
        s.save(to: defaults)
        push(s)
    }

    private func push(_ s: SharedSettings) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        try? WCSession.default.updateApplicationContext(s.context)
    }

    private func importSession(name: String, data: Data) {
        guard let context = container?.mainContext else { return }
        do {
            try SessionLibrary.upsert(name: name, data: data, into: context, raw: PhoneStorage.raw)
            lastReceived = Date()
            receivedThisLaunch += 1
            lastError = nil
        } catch {
            lastError = String(localized: "A received session couldn't be read")
        }
    }

    private func apply(context: [String: Any]) {
        guard let incoming = SharedSettings(context: context),
              incoming.shouldReplace(SharedSettings.load(from: defaults)) else { return }
        incoming.save(to: defaults)   // goal.dailyMinutes：设置页和首页的 @AppStorage 会跟着变
    }

    private func refreshStatus(_ session: WCSession, error: Error?) {
        if let error {
            status = .failed(error.localizedDescription)
        } else if !session.isPaired {
            status = .notPaired
        } else if !session.isWatchAppInstalled {
            status = .appNotInstalled
        } else {
            status = .connected
        }
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.refreshStatus(session, error: error)
            self.apply(context: context)
            if let local = SharedSettings.load(from: self.defaults) { self.push(local) }
        }
    }

    /// 系统给的临时文件在这个回调返回后就会被删，所以先同步读进内存，再回主线程写库
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let name = (file.metadata?["name"] as? String) ?? file.fileURL.lastPathComponent
        guard let data = try? Data(contentsOf: file.fileURL) else { return }
        Task { @MainActor in self.importSession(name: name, data: data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(context: applicationContext) }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshStatus(session, error: nil) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// 换了一块手表：重新激活，才能收到新手表的数据
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}

extension WatchLink.Status {
    var text: LocalizedStringKey {
        switch self {
        case .unsupported: return "This device doesn't support Apple Watch connectivity."
        case .connecting: return "Connecting to Apple Watch…"
        case .notPaired: return "No paired Apple Watch"
        case .appNotInstalled: return "Flowbeat isn't installed on your Apple Watch yet"
        case .connected: return "Apple Watch connected · sessions sync when you end a focus session"
        case .failed(let message): return "Connection failed: \(message)"
        }
    }

    var symbol: String {
        switch self {
        case .connected: return "applewatch.radiowaves.left.and.right"
        case .connecting: return "applewatch"
        default: return "applewatch.slash"
        }
    }
}
