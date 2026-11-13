import Foundation

/// 手表 app 写给小组件（表盘复杂功能 / 智能叠放）的数据，放在 App Group 共享容器里的一个 JSON 文件。
///
/// 为什么不直接存「今天 42 分钟」：小组件要自己决定「今天」是哪天——过了午夜要显示 0，
/// 换了时区「今天」也会变，而 app 那时候不一定在运行。所以存的是最近 `retentionDays` 天的
/// 15 分钟桶（所有时区偏移都是 15 分钟的整数倍，桶不会跨两个当地日期），
/// 小组件用和历史页同一个 `FocusHistory.summary` 现算。
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let fileName = "widget-snapshot.json"
    public static let bucketSeconds: TimeInterval = 15 * 60
    /// 连续达标天数最多往回看这么多天（文件保持很小）
    public static let retentionDays = 60

    public let generatedAt: Date
    public let dailyGoalMinutes: Int
    public let buckets: [MinuteBucket]

    public init(generatedAt: Date, dailyGoalMinutes: Int, buckets: [MinuteBucket]) {
        self.generatedAt = generatedAt
        self.dailyGoalMinutes = dailyGoalMinutes
        self.buckets = buckets
    }

    /// 没有任何数据时（第一次装、还没专注过）
    public static func empty(goal: Int = FocusHistory.defaultDailyGoalMinutes) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: .distantPast, dailyGoalMinutes: goal, buckets: [])
    }

    public static func make(from digests: [SessionDigest], now: Date, dailyGoalMinutes: Int) -> WidgetSnapshot {
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays + 1) * 86_400)
        var merged: [Int: MinuteBucket] = [:]
        for d in digests {
            for b in d.buckets where b.start >= cutoff {
                let key = Int((b.start.timeIntervalSince1970 / bucketSeconds).rounded(.down))
                var m = merged[key] ?? MinuteBucket(start: Date(timeIntervalSince1970: TimeInterval(key) * bucketSeconds),
                                                    scored: 0, focused: 0)
                m.scored += b.scored
                m.focused += b.focused
                merged[key] = m
            }
        }
        return WidgetSnapshot(generatedAt: now, dailyGoalMinutes: dailyGoalMinutes,
                              buckets: merged.keys.sorted().map { merged[$0]! })
    }

    /// 在 date 那一刻小组件该显示什么
    public func summary(at date: Date, calendar: Calendar) -> HistorySummary {
        FocusHistory.summary([SessionDigest(name: "widget", start: buckets.first?.start ?? date, buckets: buckets)],
                             now: date, calendar: calendar, dailyGoalMinutes: dailyGoalMinutes)
    }

    /// 时间线：现在一条 + 下一个当地午夜一条（那一刻「今天」归零），之后让系统再来要。
    /// 专注结束时 app 会主动 reloadTimelines，所以不用按分钟刷新。
    public static func timelineDates(now: Date, calendar: Calendar) -> [Date] {
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return [now]
        }
        return [now, midnight]
    }

    public func encoded() throws -> Data { try FlowbeatJSON.sessionEncoder.encode(self) }

    public static func decode(_ data: Data) -> WidgetSnapshot? {
        try? FlowbeatJSON.sessionDecoder.decode(WidgetSnapshot.self, from: data)
    }
}

/// App Group 的标识。两边（手表 app、小组件扩展）的 entitlements 里都要有它，
/// 并且要在开发者后台用 Team ID 注册（见 docs/appstore/submission-checklist.md）。
public enum AppGroup {
    public static let identifier = "group.com.xungirl.flowbeat"
}
