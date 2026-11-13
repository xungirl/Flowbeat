import Foundation

/// 走神提醒的设置。默认：连续走神 3 分钟提醒一次，两次提醒之间至少隔 10 分钟。
public struct NudgeSettings: Equatable, Sendable {
    public var enabled: Bool
    /// 连续走神多少分钟才提醒
    public var distractedMinutes: Int
    /// 两次提醒之间至少隔多少分钟（不唠叨）
    public var cooldownMinutes: Int

    public static let defaultDistractedMinutes = 3
    public static let defaultCooldownMinutes = 10
    /// 设置页 Stepper 的范围
    public static let distractedMinutesRange = 1...15
    public static let cooldownMinutesRange = 3...60

    public init(enabled: Bool = true,
                distractedMinutes: Int = NudgeSettings.defaultDistractedMinutes,
                cooldownMinutes: Int = NudgeSettings.defaultCooldownMinutes) {
        self.enabled = enabled
        self.distractedMinutes = distractedMinutes.clamped(to: Self.distractedMinutesRange)
        self.cooldownMinutes = cooldownMinutes.clamped(to: Self.cooldownMinutesRange)
    }
}

/// 走神提醒的状态机。每秒喂一次，返回「这一秒要不要轻震一下」。
///
/// 规则：
/// - 「走神」= 这一秒有分数，且分数 < `threshold`（默认 40，和圆环上「走神」的颜色同一个分界）。
/// - 连续走神满 `distractedMinutes` 分钟 → 提醒一次。
/// - 两次提醒之间至少隔 `cooldownMinutes` 分钟；提醒后连续走神要重新从 0 计。
/// - 短暂回神不算打断：分数回到阈值以上要连续 `graceSeconds` 秒（默认 15）才清零，
///   否则平滑后的分数在阈值附近抖一下就永远提醒不到。
/// - 校准期、离座（走路）、番茄钟休息、没有分数的秒：不提醒，并且清零（回来后重新计）。
public struct DistractionNudge: Equatable, Sendable {
    public struct Input: Equatable, Sendable {
        public var elapsed: TimeInterval
        /// 这一秒的分数；校准期 / 离座时为 nil
        public var score: Double?
        public var calibrating: Bool
        public var away: Bool
        public var onBreak: Bool

        public init(elapsed: TimeInterval, score: Double?, calibrating: Bool = false, away: Bool = false,
                    onBreak: Bool = false) {
            self.elapsed = elapsed
            self.score = score
            self.calibrating = calibrating
            self.away = away
            self.onBreak = onBreak
        }
    }

    public static let defaultThreshold = 40.0
    public static let defaultGraceSeconds: TimeInterval = 15

    public var settings: NudgeSettings
    public let threshold: Double
    public let graceSeconds: TimeInterval

    /// 这一段连续走神从第几秒开始；nil = 现在不在走神
    public private(set) var distractedSince: TimeInterval?
    /// 回神（分数回到阈值以上）从第几秒开始，用来算宽限期
    public private(set) var recoveredSince: TimeInterval?
    public private(set) var lastNudgeAt: TimeInterval?
    public private(set) var nudgeCount = 0

    public init(settings: NudgeSettings = NudgeSettings(), threshold: Double = DistractionNudge.defaultThreshold,
                graceSeconds: TimeInterval = DistractionNudge.defaultGraceSeconds) {
        self.settings = settings
        self.threshold = threshold
        self.graceSeconds = graceSeconds
    }

    /// 现在已经连续走神多少秒（给 UI / 测试看）
    public func distractedSeconds(at elapsed: TimeInterval) -> TimeInterval {
        distractedSince.map { elapsed - $0 } ?? 0
    }

    /// - Returns: 这一秒是否应该提醒
    public mutating func update(_ input: Input) -> Bool {
        guard settings.enabled, !input.calibrating, !input.away, !input.onBreak, let score = input.score else {
            distractedSince = nil
            recoveredSince = nil
            return false
        }
        let t = input.elapsed
        if score < threshold {
            recoveredSince = nil
            if distractedSince == nil { distractedSince = t }
        } else if distractedSince != nil {
            if recoveredSince == nil { recoveredSince = t }
            if let r = recoveredSince, t - r >= graceSeconds {
                distractedSince = nil
                recoveredSince = nil
            }
            return false   // 宽限期内不提醒，但也不清零
        }
        guard let since = distractedSince, t - since >= TimeInterval(settings.distractedMinutes * 60) else {
            return false
        }
        if let last = lastNudgeAt, t - last < TimeInterval(settings.cooldownMinutes * 60) { return false }
        lastNudgeAt = t
        nudgeCount += 1
        distractedSince = t   // 提醒过了：要再连续走神 N 分钟（且过了冷却）才会有下一次
        return true
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
