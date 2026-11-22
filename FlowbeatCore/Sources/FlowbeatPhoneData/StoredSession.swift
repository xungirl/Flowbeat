import Foundation
import SwiftData
import FlowbeatCore

/// iPhone 上的一条专注记录（SwiftData，底层是 SQLite；开了 iCloud 时由 CloudKit 同步到用户自己的私有数据库）。
///
/// 为什么这样设计：
/// - **列表和统计只读小字段**：开始/结束时间、平均分、专注秒数、按分钟的桶（`bucketsData`，1 小时 ≈ 60 个桶）。
///   逐秒的完整存档（1 小时 ≈ 3600 条样本）放在 `recordData` 里，用 `.externalStorage` 存成单独的文件，
///   只有打开详情页时才解码。
/// - **CloudKit 的限制**：同步的模型不能有 `@Attribute(.unique)`，每个属性都要有默认值或者是可选的。
///   所以「同一次专注只存一条」靠导入时按 `name` 查找 + `SessionLibrary.removeDuplicates` 清理
///   （两台设备同时导入同一个文件、iCloud 合并后可能出现重复）。
/// - `name` 是手表存档的文件名（开始时间的 ISO 8601，冒号换成 -），和手表 / 历史摘要用的是同一个键。
@Model
public final class StoredSession {
    public var name: String = ""
    public var start: Date = Date.distantPast
    public var end: Date = Date.distantPast
    /// 平均分（只算打过分的秒）；整次都在校准 / 离座时为 nil
    public var averageScore: Double?
    public var scoredSeconds: Int = 0
    /// 分数 ≥ 70 的秒数
    public var focusedSeconds: Int = 0
    public var longestStreakSeconds: Int = 0
    public var awaySeconds: Int = 0
    public var focusedLabels: Int = 0
    public var distractedLabels: Int = 0
    /// "free" / "pomodoro"
    public var mode: String = SessionMode.free.rawValue
    public var goalMinutes: Int?
    /// 用户在 iPhone 上写的备注（「写论文第三章」）。手表存档里没有，重新导入同一次专注时保留
    public var note: String = ""
    /// 这条记录最后一次从手表导入的时间（去重时留最新的）
    public var importedAt: Date = Date.distantPast
    /// `[MinuteBucket]` 的 JSON：历史统计、30 天趋势只读它
    public var bucketsData: Data?
    /// 完整的 `SessionRecord` JSON（和手表存档文件逐字节一样），详情页和导出用
    @Attribute(.externalStorage) public var recordData: Data?

    public init(name: String) {
        self.name = name
    }

    public var durationSeconds: Double { max(0, end.timeIntervalSince(start)) }
    public var focusedMinutes: Int { focusedSeconds / 60 }
    public var focusedRatio: Double? { scoredSeconds > 0 ? Double(focusedSeconds) / Double(scoredSeconds) : nil }
    public var sessionMode: SessionMode { SessionMode(rawValue: mode) ?? .free }
    public var goalMet: Bool? { goalMinutes.map { focusedMinutes >= $0 } }

    /// 解码完整存档（详情页用，不要在列表里调）
    public func record() -> SessionRecord? {
        guard let recordData else { return nil }
        return try? FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: recordData)
    }

    public var buckets: [MinuteBucket] {
        guard let bucketsData,
              let list = try? FlowbeatJSON.sessionDecoder.decode([MinuteBucket].self, from: bucketsData) else { return [] }
        return list
    }

    /// 给 FocusHistory 用的摘要（和手表历史页同一套算法：今天、7 天、连续达标、最佳时段）
    public var digest: SessionDigest { SessionDigest(name: name, start: start, buckets: buckets) }

    /// 用一份存档覆盖所有从手表来的字段（备注不动）
    func apply(record: SessionRecord, data: Data, importedAt: Date) {
        let samples = record.samples
        start = samples.first?.t ?? Date.distantPast
        end = samples.last?.t ?? start
        averageScore = SessionStats.averageScore(samples)
        scoredSeconds = samples.filter { $0.score != nil }.count
        focusedSeconds = SessionStats.focusedSeconds(samples)
        longestStreakSeconds = SessionStats.longestFocusStreak(samples)
        awaySeconds = samples.filter(\.away).count
        focusedLabels = samples.filter { $0.label == "focused" }.count
        distractedLabels = samples.filter { $0.label == "distracted" }.count
        mode = (record.plan?.mode ?? .free).rawValue
        goalMinutes = record.plan?.goalMinutes
        bucketsData = try? FlowbeatJSON.sessionEncoder.encode(SessionDigest.make(name: name, record: record).buckets)
        recordData = data
        self.importedAt = importedAt
    }
}
