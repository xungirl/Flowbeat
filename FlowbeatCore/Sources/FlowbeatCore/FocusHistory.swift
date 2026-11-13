import Foundation

// 手表上的历史统计：今天专注了多少分钟、最近 7 天、连续达标天数、一天里什么时候最专注。
//
// 关键设计：存档压缩成「每分钟一个桶」，桶的时间是绝对时间（UTC 的整分钟），
// 按哪一天、哪个小时归类留到显示时再用当时的 Calendar（含时区）算。这样：
// - 一次跨午夜的专注，前半段算昨天、后半段算今天（按每一秒自己的时间，而不是开始时间）；
// - 出差换时区后，「今天」按新时区重新划分，不用改任何存档；
// - 夏令时那天只有 23 / 25 小时也没关系：Calendar 负责算一天从哪开始。

/// 一分钟里打过分的秒数和专注（分数 ≥ 70）的秒数
public struct MinuteBucket: Codable, Equatable, Sendable {
    /// 这一分钟的开始（UTC 整分钟，和时区无关）
    public let start: Date
    public var scored: Int
    public var focused: Int

    public init(start: Date, scored: Int, focused: Int) {
        self.start = start
        self.scored = scored
        self.focused = focused
    }
}

/// 一次专注的摘要：比原始存档小两个数量级（1 小时 = 60 个桶，而不是 3600 条样本），
/// 历史页和小组件只读它。由存档算出来，可以随时重建。
public struct SessionDigest: Codable, Equatable, Sendable {
    /// 存档文件名（不带 .json），也是去重的键
    public let name: String
    public let start: Date
    public let buckets: [MinuteBucket]
    /// 这次打的标签对应的特征（个性化模型的训练数据，见 PersonalModel.swift）。v1.0 的缓存没有这个字段
    public var labels: [LabeledFeatures]?

    public init(name: String, start: Date, buckets: [MinuteBucket], labels: [LabeledFeatures]? = nil) {
        self.name = name
        self.start = start
        self.buckets = buckets
        self.labels = labels
    }

    public static func make(name: String, record: SessionRecord,
                            threshold: Double = SessionStats.focusThreshold) -> SessionDigest {
        var byMinute: [Int: MinuteBucket] = [:]
        for s in record.samples {
            guard let score = s.score else { continue }   // 校准 / 离座 / 休息不计
            let minute = Int((s.t.timeIntervalSince1970 / 60).rounded(.down))
            var b = byMinute[minute] ?? MinuteBucket(start: Date(timeIntervalSince1970: TimeInterval(minute * 60)),
                                                     scored: 0, focused: 0)
            b.scored += 1
            if score >= threshold { b.focused += 1 }
            byMinute[minute] = b
        }
        return SessionDigest(name: name, start: record.samples.first?.t ?? .distantPast,
                             buckets: byMinute.keys.sorted().map { byMinute[$0]! },
                             labels: LabeledFeatures.extract(from: record))
    }
}

extension Array where Element == SessionDigest {
    /// 所有存档里的标签训练样本（按时间顺序）
    public var allLabels: [LabeledFeatures] { flatMap { $0.labels ?? [] } }
}

public struct DayTotal: Equatable, Sendable, Identifiable {
    /// 当地这一天的 0 点
    public let day: Date
    public let focusedMinutes: Int
    public var id: Date { day }

    public init(day: Date, focusedMinutes: Int) {
        self.day = day
        self.focusedMinutes = focusedMinutes
    }
}

public struct BestHour: Equatable, Sendable {
    /// 当地时间 0…23
    public let hour: Int
    /// 这个小时里打过分的时间有多少比例是专注的
    public let focusedRatio: Double
    public let scoredMinutes: Int
}

public struct HistorySummary: Equatable, Sendable {
    public let todayMinutes: Int
    /// 最近 7 天（最旧的在前，最后一个是今天），没专注的天也在（0 分钟）
    public let week: [DayTotal]
    /// 连续达到每日目标的天数。今天还没达标时从昨天往前数（今天还没结束，不算断）
    public let streak: Int
    public let dailyGoalMinutes: Int
    public let bestHour: BestHour?
    public var todayGoalMet: Bool { todayMinutes >= dailyGoalMinutes }
    public var todayProgress: Double {
        dailyGoalMinutes > 0 ? min(1, Double(todayMinutes) / Double(dailyGoalMinutes)) : 0
    }
}

public enum FocusHistory {
    public static let defaultDailyGoalMinutes = 60
    public static let dailyGoalRange = 10...240
    /// 一个小时至少要有这么多分钟打过分，才参与「最佳时段」（避免 2 分钟 100% 胜出）
    public static let bestHourMinScoredMinutes = 10

    /// 每个当地日期（0 点）专注了多少秒
    public static func focusedSecondsByDay(_ digests: [SessionDigest], calendar: Calendar) -> [Date: Int] {
        var days: [Date: Int] = [:]
        for d in digests {
            for b in d.buckets where b.focused > 0 {
                days[calendar.startOfDay(for: b.start), default: 0] += b.focused
            }
        }
        return days
    }

    /// 从 today 往前连续多少天满足目标；today 没达标就从昨天开始数
    public static func streak(days: [Date: Int], today: Date, goalMinutes: Int, calendar: Calendar) -> Int {
        let goal = max(1, goalMinutes) * 60
        var day = calendar.startOfDay(for: today)
        if (days[day] ?? 0) < goal {
            guard let y = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = y
        }
        var count = 0
        while (days[day] ?? 0) >= goal {
            count += 1
            // 用 Calendar 往前推一天，不是减 86400 秒（夏令时那天不是 24 小时）
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    public static func bestHour(_ digests: [SessionDigest], calendar: Calendar,
                                minScoredMinutes: Int = bestHourMinScoredMinutes) -> BestHour? {
        var scored = [Int](repeating: 0, count: 24), focused = [Int](repeating: 0, count: 24)
        for d in digests {
            for b in d.buckets {
                let h = calendar.component(.hour, from: b.start)
                scored[h] += b.scored
                focused[h] += b.focused
            }
        }
        let candidates = (0..<24).filter { scored[$0] >= minScoredMinutes * 60 }
        let best = candidates.max { a, b in
            let ra = Double(focused[a]) / Double(scored[a]), rb = Double(focused[b]) / Double(scored[b])
            return ra != rb ? ra < rb : focused[a] < focused[b]   // 比例一样时，专注时间多的胜出
        }
        return best.map { BestHour(hour: $0, focusedRatio: Double(focused[$0]) / Double(scored[$0]),
                                   scoredMinutes: scored[$0] / 60) }
    }

    public static func summary(_ digests: [SessionDigest], now: Date, calendar: Calendar,
                               dailyGoalMinutes: Int = defaultDailyGoalMinutes) -> HistorySummary {
        let days = focusedSecondsByDay(digests, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let week: [DayTotal] = (0..<7).reversed().compactMap { back in
            guard let d = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return DayTotal(day: d, focusedMinutes: (days[d] ?? 0) / 60)
        }
        return HistorySummary(todayMinutes: (days[today] ?? 0) / 60, week: week,
                              streak: streak(days: days, today: now, goalMinutes: dailyGoalMinutes, calendar: calendar),
                              dailyGoalMinutes: dailyGoalMinutes,
                              bestHour: bestHour(digests, calendar: calendar))
    }
}

/// 摘要缓存：一个 JSON 文件。refresh 时只解析新出现的存档，删掉的存档对应的摘要也删掉。
/// 只用 Foundation，测试用临时目录。
public struct DigestStore {
    public let file: URL

    public init(file: URL) { self.file = file }

    public func load() -> [SessionDigest] {
        guard let data = try? Data(contentsOf: file),
              let list = try? FlowbeatJSON.sessionDecoder.decode([SessionDigest].self, from: data) else { return [] }
        return list
    }

    public func save(_ digests: [SessionDigest]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FlowbeatJSON.sessionEncoder.encode(digests).write(to: file, options: .atomic)
    }

    /// 和存档目录对齐，返回最新的摘要列表（按开始时间排序）
    @discardableResult
    public func refresh(archiveDirectory: URL) -> [SessionDigest] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: nil)) ?? []
        let names = Set(files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
        var cached = Dictionary(load().map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        // 没有 labels 字段的旧缓存重新解析一次，拿到标签特征
        for name in names where cached[name] == nil || cached[name]?.labels == nil {
            let url = archiveDirectory.appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: url),
                  let record = try? FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: data) else { continue }
            cached[name] = SessionDigest.make(name: name, record: record)
            changed = true
        }
        for name in cached.keys where !names.contains(name) {
            cached[name] = nil
            changed = true
        }
        let list = cached.values.sorted { $0.start < $1.start }
        if changed { try? save(list) }
        return list
    }
}
