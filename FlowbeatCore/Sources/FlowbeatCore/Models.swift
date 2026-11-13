import Foundation

// 手表 ↔ 后端的数据格式，和 backend/app/schemas.py 一一对应。
// JSON 用 snake_case（FlowbeatJSON.encoder 自动把 hrMean 转成 hr_mean）。
// 字段名的一致性由 contract/window_summary_fields.json 在 Swift 和 Python 两边各测一次。

/// 一个时间点的记录。存成 JSON，以后拿来画曲线、训练你自己的模型。
public struct FocusSample: Codable, Equatable, Sendable {
    public let t: Date
    public let heartRate: Double?
    public let motion: Double
    public let score: Double?
    /// 你手动打的标签："focused" / "distracted"，平时为 nil
    public let label: String?
    /// 这一秒是否离座（走路 / 跑步），离座时不打分
    public var away: Bool = false

    public init(t: Date, heartRate: Double?, motion: Double, score: Double?, label: String?, away: Bool = false) {
        self.t = t
        self.heartRate = heartRate
        self.motion = motion
        self.score = score
        self.label = label
        self.away = away
    }
}

/// 一次专注的完整存档：逐秒样本 + AI 窗口摘要 + AI 判断 + 复盘
public struct SessionRecord: Codable, Equatable, Sendable {
    public let samples: [FocusSample]
    public let windows: [WindowSummary]
    public let judgments: [Judgment]
    public let review: Review?
    /// 每个判断属于第几分钟的窗口（离线排队后判断可能晚到，靠这个对齐时间轴）。旧存档没有这个字段。
    public let timeline: [JudgedWindow]?

    public init(samples: [FocusSample], windows: [WindowSummary], judgments: [Judgment], review: Review?,
                timeline: [JudgedWindow]? = nil) {
        self.samples = samples
        self.windows = windows
        self.judgments = judgments
        self.review = review
        self.timeline = timeline
    }
}

/// 一个窗口的 AI 判断，带上窗口所在的分钟
public struct JudgedWindow: Codable, Equatable, Sendable {
    public let minute: Int
    public let judgment: Judgment

    public init(minute: Int, judgment: Judgment) {
        self.minute = minute
        self.judgment = judgment
    }
}

public struct WindowSummary: Codable, Equatable, Sendable {
    public var minuteOfSession: Int
    public var localTime: String
    public var baselineHr: Double?
    public var hrMean: Double?
    public var hrMin: Double?
    public var hrMax: Double?
    public var hrTrend: Double?
    public var motionMean: Double
    public var motionMax: Double
    public var stillRatio: Double
    public var awaySeconds: Int
    /// 手表本地规则分。照样发给后端（存档、复盘、离线兜底要用），但后端默认不放进 LLM 提示词，避免锚定。
    public var ruleScoreMean: Double?

    public init(minuteOfSession: Int, localTime: String, baselineHr: Double? = nil, hrMean: Double? = nil,
                hrMin: Double? = nil, hrMax: Double? = nil, hrTrend: Double? = nil, motionMean: Double,
                motionMax: Double, stillRatio: Double, awaySeconds: Int, ruleScoreMean: Double? = nil) {
        self.minuteOfSession = minuteOfSession
        self.localTime = localTime
        self.baselineHr = baselineHr
        self.hrMean = hrMean
        self.hrMin = hrMin
        self.hrMax = hrMax
        self.hrTrend = hrTrend
        self.motionMean = motionMean
        self.motionMax = motionMax
        self.stillRatio = stillRatio
        self.awaySeconds = awaySeconds
        self.ruleScoreMean = ruleScoreMean
    }

    /// 低于这个加速度（g）算「手腕静止」
    public static let stillThreshold = 0.03

    /// 把一段逐秒样本压缩成摘要：只发统计量，不发原始数据，省流量、保护隐私，也更好让模型理解
    public static func make(from samples: [FocusSample], baseline: Double?, sessionStart: Date,
                            timeZone: TimeZone = .current) -> WindowSummary {
        let hrs = samples.compactMap(\.heartRate)
        let motions = samples.map(\.motion)
        let scores = samples.compactMap(\.score)
        let end = samples.last?.t ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.timeZone = timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return WindowSummary(
            minuteOfSession: max(0, Int(end.timeIntervalSince(sessionStart) / 60)),
            localTime: fmt.string(from: end),
            baselineHr: baseline.map(round1),
            hrMean: hrs.isEmpty ? nil : round1(hrs.reduce(0, +) / Double(hrs.count)),
            hrMin: hrs.min().map(round1),
            hrMax: hrs.max().map(round1),
            hrTrend: (hrs.first != nil && hrs.last != nil) ? round1(hrs.last! - hrs.first!) : nil,
            motionMean: round3(motions.isEmpty ? 0 : motions.reduce(0, +) / Double(motions.count)),
            motionMax: round3(motions.max() ?? 0),
            stillRatio: round3(motions.isEmpty ? 0 : Double(motions.filter { $0 < stillThreshold }.count) / Double(motions.count)),
            awaySeconds: samples.filter(\.away).count,
            ruleScoreMean: scores.isEmpty ? nil : round1(scores.reduce(0, +) / Double(scores.count))
        )
    }
}

func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

public struct Judgment: Codable, Equatable, Sendable {
    public var state: String   // focused / distracted / away / unclear
    public var score: Int
    public var reason: String
    /// "llm" = 大模型判断；"fallback" = 模型超时/出错，后端按规则分兜底。旧后端不返回这个字段。
    public var source: String?

    public init(state: String, score: Int, reason: String, source: String? = nil) {
        self.state = state
        self.score = score
        self.reason = reason
        self.source = source
    }
}

public struct LabeledExample: Codable, Equatable, Sendable {
    public var window: WindowSummary
    public var label: String   // focused / distracted

    public init(window: WindowSummary, label: String) {
        self.window = window
        self.label = label
    }

    /// 追加一条，只保留最近 maxCount 条（后端最多收 20 条）
    public static func appending(_ example: LabeledExample, to list: [LabeledExample], maxCount: Int = 20) -> [LabeledExample] {
        var list = list
        list.append(example)
        if list.count > maxCount { list.removeFirst(list.count - maxCount) }
        return list
    }
}

public struct Review: Codable, Equatable, Sendable {
    public var summary: String
    public var tip: String
    /// "llm" 或 "fallback"（模型不可用时后端按统计数字拼的总结）
    public var source: String?

    public init(summary: String, tip: String, source: String? = nil) {
        self.summary = summary
        self.tip = tip
        self.source = source
    }
}

public struct JudgeRequest: Codable, Equatable, Sendable {
    public var window: WindowSummary
    public var examples: [LabeledExample]
    public var recent: [Judgment]

    public init(window: WindowSummary, examples: [LabeledExample], recent: [Judgment]) {
        self.window = window
        self.examples = examples
        self.recent = recent
    }
}

public struct ReviewRequest: Codable, Equatable, Sendable {
    public var durationMinutes: Int
    public var averageScore: Double?
    public var focusedRatio: Double?
    public var awayCount: Int
    public var awayMinutes: Double
    public var windows: [WindowSummary]
    public var judgments: [Judgment]

    public init(durationMinutes: Int, averageScore: Double?, focusedRatio: Double?, awayCount: Int,
                awayMinutes: Double, windows: [WindowSummary], judgments: [Judgment]) {
        self.durationMinutes = durationMinutes
        self.averageScore = averageScore
        self.focusedRatio = focusedRatio
        self.awayCount = awayCount
        self.awayMinutes = awayMinutes
        self.windows = windows
        self.judgments = judgments
    }
}

/// 和后端通信用的编解码器（snake_case）。存档 JSON 用 `sessionEncoder`（日期 ISO 8601）。
public enum FlowbeatJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static var sessionEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var sessionDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
