import Foundation

/// 把一个 SessionRecord（逐秒样本）整理成 iPhone 图表要画的东西。纯逻辑，单元测试覆盖。
///
/// - 分数按 `bucketSeconds` 分桶取平均（1 小时 = 3600 个点太密，图表也慢）。
/// - 离座 / 校准没有分数，曲线在那里断开：用 `segment` 区分连续的段，图表按段画线。
/// - 你打的「专注 / 走神」标签、离座区间、AI 判断都换算成「第几分钟」。
public struct SessionTimeline: Equatable {
    public struct ScorePoint: Equatable, Identifiable {
        public let id: Int
        public let minute: Double
        public let score: Double
        /// 连续的一段曲线编号；中间隔了没分数的桶（离座、校准）就换下一段
        public let segment: Int
    }

    public struct LabelMark: Equatable, Identifiable {
        public var id: Double { minute }
        public let minute: Double
        public let label: String
    }

    public struct AwaySpan: Equatable, Identifiable {
        public var id: Double { start }
        public let start: Double
        public let end: Double
    }

    public struct JudgmentPoint: Equatable, Identifiable {
        public let id: Int
        public let minute: Double
        public let judgment: Judgment
    }

    public let start: Date?
    public let durationMinutes: Double
    public let averageScore: Double?
    public let focusedRatio: Double?
    public let scores: [ScorePoint]
    public let labels: [LabelMark]
    public let awaySpans: [AwaySpan]
    public let judgments: [JudgmentPoint]

    public var awayCount: Int { awaySpans.count }

    public init(record: SessionRecord, bucketSeconds: Int = 10) {
        precondition(bucketSeconds > 0)
        let samples = record.samples
        let t0 = samples.first?.t
        start = t0
        func minute(_ d: Date) -> Double { t0.map { d.timeIntervalSince($0) / 60 } ?? 0 }

        durationMinutes = samples.last.map { minute($0.t) } ?? 0
        averageScore = SessionStats.averageScore(samples)
        focusedRatio = SessionStats.focusedRatio(samples)

        // 分桶
        var buckets: [Int: [Double]] = [:]
        for s in samples {
            guard let score = s.score, let t0 else { continue }
            let b = Int(s.t.timeIntervalSince(t0)) / bucketSeconds
            buckets[b, default: []].append(score)
        }
        var points: [ScorePoint] = []
        var segment = 0
        var lastBucket: Int?
        for b in buckets.keys.sorted() {
            if let last = lastBucket, b != last + 1 { segment += 1 }
            let vals = buckets[b]!
            // 点画在桶的中间
            let m = (Double(b) + 0.5) * Double(bucketSeconds) / 60
            points.append(ScorePoint(id: b, minute: m, score: vals.reduce(0, +) / Double(vals.count), segment: segment))
            lastBucket = b
        }
        scores = points

        labels = samples.compactMap { s in s.label.map { LabelMark(minute: minute(s.t), label: $0) } }

        // 连续的离座秒数合成一段
        var spans: [AwaySpan] = []
        var spanStart: Double?
        for s in samples {
            if s.away, spanStart == nil { spanStart = minute(s.t) }
            if !s.away, let st = spanStart {
                spans.append(AwaySpan(start: st, end: minute(s.t)))
                spanStart = nil
            }
        }
        if let st = spanStart, let last = samples.last { spans.append(AwaySpan(start: st, end: minute(last.t))) }
        awaySpans = spans

        // AI 判断：新存档有 timeline（窗口分钟 → 判断）；旧存档只能按顺序和 windows 对齐（尽力而为）
        if let tl = record.timeline {
            judgments = tl.enumerated().map {
                JudgmentPoint(id: $0.offset, minute: $0.element.endSeconds.map { $0 / 60 } ?? Double($0.element.minute),
                              judgment: $0.element.judgment)
            }
        } else {
            judgments = zip(record.windows, record.judgments).enumerated().map {
                JudgmentPoint(id: $0.offset, minute: Double($0.element.0.minuteOfSession), judgment: $0.element.1)
            }
        }
    }
}
