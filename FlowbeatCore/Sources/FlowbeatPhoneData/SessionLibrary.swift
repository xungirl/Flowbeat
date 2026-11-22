import Foundation
import SwiftData
import FlowbeatCore

/// 建 SwiftData 容器。iCloud 同步只在 Info.plist 里写了容器名（`FlowbeatCloudKitContainer`）时打开：
/// 免费开发者账号不能用 iCloud，真机测试用的 devtest 工程不写这个键，就只存在本机。
public enum FlowbeatStore {
    public static let schema = Schema([StoredSession.self])

    public enum Location: Equatable {
        case inMemory
        case local
        case iCloud(container: String)
    }

    public static func makeContainer(_ location: Location) throws -> ModelContainer {
        let config: ModelConfiguration
        switch location {
        case .inMemory:
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        case .local:
            config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        case .iCloud(let id):
            config = ModelConfiguration(schema: schema, cloudKitDatabase: .private(id))
        }
        return try ModelContainer(for: schema, configurations: config)
    }

    /// App 启动时用：有容器名就开 iCloud，失败（比如 entitlement 不对）退回本机，再失败退回内存，app 不会因此打不开
    public static func makeAppContainer(cloudKitContainer: String?) -> (container: ModelContainer, location: Location) {
        var tries: [Location] = [.local, .inMemory]
        if let id = cloudKitContainer, !id.isEmpty { tries.insert(.iCloud(container: id), at: 0) }
        for location in tries {
            if let c = try? makeContainer(location) { return (c, location) }
        }
        fatalError("SwiftData in-memory container failed")
    }
}

/// 导入、去重、统计、导出。全部是对 ModelContext 的操作，测试里用内存容器跑。
public enum SessionLibrary {
    public enum ImportResult: Equatable {
        case inserted
        case updated
    }

    /// 收到手表的一份存档：同名的就更新（备注保留），没有就新建。坏文件抛错，不写库。
    @discardableResult
    public static func upsert(name rawName: String, data: Data, into context: ModelContext,
                              now: Date = Date()) throws -> ImportResult {
        let record = try FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: data)
        let name = normalizedName(rawName)
        let existing = try sessions(named: name, in: context)
        let result: ImportResult
        let target: StoredSession
        if let first = existing.first {
            target = first
            result = .updated
            // 已经有重复（iCloud 合并来的）就顺手清掉，备注合并到留下的那条
            for extra in existing.dropFirst() {
                if target.note.isEmpty { target.note = extra.note }
                context.delete(extra)
            }
        } else {
            target = StoredSession(name: name)
            context.insert(target)
            result = .inserted
        }
        target.apply(record: record, data: data, importedAt: now)
        try context.save()
        return result
    }

    /// 文件名 → 键：去掉目录和 .json 后缀
    public static func normalizedName(_ raw: String) -> String {
        let last = URL(fileURLWithPath: raw).lastPathComponent
        return last.hasSuffix(".json") ? String(last.dropLast(5)) : last
    }

    public static func sessions(named name: String, in context: ModelContext) throws -> [StoredSession] {
        var d = FetchDescriptor<StoredSession>(predicate: #Predicate { $0.name == name })
        d.sortBy = [SortDescriptor(\.importedAt, order: .reverse)]
        return try context.fetch(d)
    }

    /// 全部记录，最新的在前
    public static func all(in context: ModelContext) throws -> [StoredSession] {
        try context.fetch(FetchDescriptor<StoredSession>(sortBy: [SortDescriptor(\.start, order: .reverse)]))
    }

    /// 同名的只留最近导入的一条（备注不为空的优先保留它的备注）。返回删掉了几条
    @discardableResult
    public static func removeDuplicates(in context: ModelContext) throws -> Int {
        let list = try context.fetch(FetchDescriptor<StoredSession>(sortBy: [SortDescriptor(\.importedAt, order: .reverse)]))
        var kept: [String: StoredSession] = [:]
        var removed = 0
        for s in list {
            if let keep = kept[s.name] {
                if keep.note.isEmpty { keep.note = s.note }
                context.delete(s)
                removed += 1
            } else {
                kept[s.name] = s
            }
        }
        if removed > 0 { try context.save() }
        return removed
    }

    /// 旧版 iPhone 端把存档存成 Documents/sessions/*.json，第一次启动新版时导进数据库。
    /// 导入成功的文件删掉（数据库里有一份逐字节相同的），解析失败的留着不动。返回导入了几条
    @discardableResult
    public static func importLegacyArchive(directory: URL, into context: ModelContext, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  (try? upsert(name: url.lastPathComponent, data: data, into: context, now: now)) != nil else { continue }
            try? fm.removeItem(at: url)
            count += 1
        }
        return count
    }
}

// MARK: - 统计

/// iPhone 首页的数字。今天 / 7 天 / 连续达标 / 最佳时段直接复用手表的 FocusHistory，
/// iPhone 额外多一个 30 天趋势和累计数字。
public struct PhoneOverview: Equatable {
    public let history: HistorySummary
    /// 最近 30 天每天专注的分钟数（最旧的在前，最后一个是今天）
    public let month: [DayTotal]
    public let totalSessions: Int
    public let totalFocusedMinutes: Int
    /// 最近 30 天里有专注的日子的平均分钟数
    public let activeDayAverageMinutes: Int?
    public let focusedLabels: Int
    public let distractedLabels: Int

    public static func make(_ sessions: [StoredSession], now: Date, calendar: Calendar,
                            dailyGoalMinutes: Int) -> PhoneOverview {
        let digests = sessions.map(\.digest)
        let history = FocusHistory.summary(digests, now: now, calendar: calendar, dailyGoalMinutes: dailyGoalMinutes)
        let days = FocusHistory.focusedSecondsByDay(digests, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let month: [DayTotal] = (0..<30).reversed().compactMap { back in
            guard let d = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return DayTotal(day: d, focusedMinutes: (days[d] ?? 0) / 60)
        }
        let active = month.filter { $0.focusedMinutes > 0 }
        return PhoneOverview(
            history: history,
            month: month,
            totalSessions: sessions.count,
            totalFocusedMinutes: sessions.reduce(0) { $0 + $1.focusedSeconds } / 60,
            activeDayAverageMinutes: active.isEmpty ? nil : active.reduce(0) { $0 + $1.focusedMinutes } / active.count,
            focusedLabels: sessions.reduce(0) { $0 + $1.focusedLabels },
            distractedLabels: sessions.reduce(0) { $0 + $1.distractedLabels }
        )
    }
}

// MARK: - 导出

/// 导出成 CSV（一行一次专注），给用户自己用 Numbers / Excel 分析。
public enum SessionCSV {
    public static let header = "start,end,duration_min,focused_min,average_score,focused_ratio,longest_streak_min,away_min,mode,goal_min,goal_met,focused_labels,distracted_labels,note"

    public static func make(_ sessions: [StoredSession]) -> String {
        let iso = ISO8601DateFormatter()
        func num(_ x: Double?, _ digits: Int = 1) -> String {
            guard let x else { return "" }
            return String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), x)
        }
        let rows = sessions.sorted { $0.start < $1.start }.map { s -> String in
            [
                iso.string(from: s.start),
                iso.string(from: s.end),
                num(s.durationSeconds / 60),
                String(s.focusedMinutes),
                num(s.averageScore),
                num(s.focusedRatio, 3),
                num(Double(s.longestStreakSeconds) / 60),
                num(Double(s.awaySeconds) / 60),
                s.mode,
                s.goalMinutes.map(String.init) ?? "",
                s.goalMet.map { $0 ? "yes" : "no" } ?? "",
                String(s.focusedLabels),
                String(s.distractedLabels),
                escape(s.note),
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    /// RFC 4180：有逗号、引号、换行的字段用双引号包起来，里面的引号写两遍。
    /// 以 = + - @ 开头的加一个单引号，防止 Excel 把备注当公式执行（CSV 注入）
    static func escape(_ field: String) -> String {
        var f = field
        if let c = f.first, "=+-@".contains(c) { f = "'" + f }
        if f.contains(where: { ",\"\n\r".contains($0) }) {
            return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return f
    }
}
