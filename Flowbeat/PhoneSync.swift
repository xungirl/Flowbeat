import Foundation
import WatchConnectivity
import FlowbeatCore

/// 手表 → iPhone：把专注存档 JSON 传给 iPhone 上的 Flowbeat（存进数据库），并双向同步每日目标。
///
/// 用 `transferFile` 而不是 `sendMessage`：
/// - sendMessage 要求 iPhone app 此刻可达（在前台或能被唤醒），手机不在身边就失败；
/// - transferFile 由系统排队、后台传输，手机不在身边时等重新连上再送，app 被杀掉也不会丢。
///
/// 补传：每次激活、每次专注结束都把「还没送达」的存档全发一遍（`SyncLedger` 记哪些已经送达）。
/// 所以先只用手表、以后才装 iPhone app，以前的记录也会补过去；某次传输失败，下次会重发。
final class PhoneSync: NSObject, WCSessionDelegate {
    static let shared = PhoneSync()

    private let defaults = UserDefaults.standard
    /// 只在主线程读写
    private var ledger = SyncLedger.load(from: .standard)

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// 专注结束、存档写好之后调用
    func sessionSaved() {
        DispatchQueue.main.async { self.sendPending() }
    }

    /// 每日目标在手表上改了：记下修改时间，告诉 iPhone
    func dailyGoalChanged(to minutes: Int) {
        let s = SharedSettings(dailyGoalMinutes: minutes, updatedAt: Date())
        s.save(to: defaults)
        pushSettings(s)
    }

    // MARK: - 存档补传

    private func sendPending() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        // 没激活：激活完成的回调里会再调一次。没装 iPhone 端（只用手表）就不发
        guard s.activationState == .activated, s.isCompanionAppInstalled,
              let dir = FocusSession.sessionsDirectory else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let names = files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }
        ledger.prune(keeping: names)
        ledger.save(to: defaults)
        let inFlight = Set(s.outstandingFileTransfers.compactMap { $0.file.metadata?["name"] as? String }
            .map { ($0 as NSString).deletingPathExtension })
        for name in ledger.pending(archive: names, inFlight: inFlight) {
            s.transferFile(dir.appendingPathComponent("\(name).json"),
                           metadata: ["kind": "session", "name": "\(name).json"])
        }
    }

    // MARK: - 设置

    private func pushSettings(_ settings: SharedSettings) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(settings.context)
    }

    private func apply(context: [String: Any]) {
        guard let incoming = SharedSettings(context: context) else { return }
        DispatchQueue.main.async {
            guard incoming.shouldReplace(SharedSettings.load(from: self.defaults)) else { return }
            incoming.save(to: self.defaults)   // 写的是 goal.dailyMinutes，设置页的 @AppStorage 会跟着变
            Task { @MainActor in HistoryStore.shared.refresh() }
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        apply(context: session.receivedApplicationContext)
        DispatchQueue.main.async {
            self.sendPending()
            if let local = SharedSettings.load(from: self.defaults) { self.pushSettings(local) }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(context: applicationContext)
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard error == nil, let name = fileTransfer.file.metadata?["name"] as? String else { return }
        DispatchQueue.main.async {
            self.ledger.markDelivered((name as NSString).deletingPathExtension)
            self.ledger.save(to: self.defaults)
        }
    }

    /// iPhone 端装上了（或被删了）：装上时补传全部历史
    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.sendPending() }
    }
}
