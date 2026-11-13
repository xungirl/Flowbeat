import Foundation
import FlowbeatCore

/// 历史统计的数据源：存档目录 → 摘要缓存（FlowbeatCore.DigestStore）→ HistorySummary。
/// 解析存档在后台线程做；只有新存档才会被解析，之后都读缓存。
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var summary: HistorySummary?
    @Published private(set) var digests: [SessionDigest] = []

    static let dailyGoalKey = "goal.dailyMinutes"

    static var dailyGoalMinutes: Int {
        let d = UserDefaults.standard
        return d.object(forKey: dailyGoalKey) == nil ? FocusHistory.defaultDailyGoalMinutes : d.integer(forKey: dailyGoalKey)
    }

    private var store: DigestStore? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { DigestStore(file: $0.appendingPathComponent("Flowbeat/digests.json")) }
    }

    /// 读存档、算统计。专注结束存档后、打开 app、改每日目标时调用
    func refresh() {
        let goal = Self.dailyGoalMinutes
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-demoHistory") {
            apply(Self.demoDigests(), goal: goal)
            return
        }
        #endif
        guard let store, let dir = FocusSession.sessionsDirectory else { return }
        Task.detached(priority: .utility) {
            let list = store.refresh(archiveDirectory: dir)
            await MainActor.run { self.apply(list, goal: goal) }
        }
    }

    private func apply(_ list: [SessionDigest], goal: Int) {
        digests = list
        summary = FocusHistory.summary(list, now: Date(), calendar: .current, dailyGoalMinutes: goal)
    }

    #if targetEnvironment(simulator)
    /// 模拟器截图用的示例历史（-demoHistory），只在内存里，不写盘。固定的数，不是测量结果。
    static func demoDigests() -> [SessionDigest] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // 过去 7 天每天专注的分钟数（最后一个是今天），和开始的钟点
        let plan: [(minutes: Int, hour: Int)] = [(35, 14), (72, 9), (64, 10), (0, 0), (81, 9), (66, 9), (42, 9)]
        return plan.enumerated().compactMap { i, p in
            guard p.minutes > 0, let day = cal.date(byAdding: .day, value: i - 6, to: today),
                  let start = cal.date(byAdding: .hour, value: p.hour, to: day) else { return nil }
            // 每分钟 50 秒专注、60 秒打分，外加 10 分钟走神
            let focusedMinutes = Int((Double(p.minutes) * 60 / 50).rounded())
            let buckets = (0..<(focusedMinutes + 10)).map { m in
                MinuteBucket(start: start.addingTimeInterval(TimeInterval(m * 60)), scored: 60,
                             focused: m < focusedMinutes ? 50 : 0)
            }
            return SessionDigest(name: "demo-\(i)", start: start, buckets: buckets)
        }
    }
    #endif
}
