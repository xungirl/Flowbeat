import Foundation
import WatchConnectivity

/// 结束一次专注后，把存档 JSON 发给 iPhone 上的 Flowbeat。
///
/// 用 `transferFile` 而不是 `sendMessage`：
/// - sendMessage 要求 iPhone app 此刻可达（在前台或能被唤醒），手机不在身边就失败；
/// - transferFile 由系统排队、后台传输，手机不在身边时等重新连上再送，app 被杀掉也不会丢。
/// 这和手表「离线也能用」的设计一致：数据先存在手表上，能传时再传。
final class PhoneSync: NSObject, WCSessionDelegate {
    static let shared = PhoneSync()

    /// 激活完成前就要发的文件，激活后补发
    private var pending: [URL] = []

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(sessionFile url: URL) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else {
            pending.append(url)
            return
        }
        // 没装 iPhone 端（比如只用手表）就不发
        guard s.isCompanionAppInstalled else { return }
        s.transferFile(url, metadata: ["kind": "session", "name": url.lastPathComponent])
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        DispatchQueue.main.async {
            let files = self.pending
            self.pending.removeAll()
            files.forEach { self.send(sessionFile: $0) }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // 失败时系统不会自动重试；文件还在 Documents/sessions 里，下次结束专注时不会重发旧文件（v1 的已知限制）
    }
}
