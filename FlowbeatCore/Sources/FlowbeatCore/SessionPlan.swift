import Foundation

/// 专注模式：自由计时（v1 的行为，一直专注到你点结束），或番茄钟（工作 / 休息交替）。
public enum SessionMode: String, Codable, Equatable, Sendable, CaseIterable {
    case free
    case pomodoro
}

public struct PomodoroSettings: Equatable, Codable, Sendable {
    public var workMinutes: Int
    public var breakMinutes: Int

    public static let defaultWorkMinutes = 25
    public static let defaultBreakMinutes = 5
    /// 工作段至少 5 分钟：前 60 秒是校准，太短的工作段没法打分
    public static let workMinutesRange = 5...90
    public static let breakMinutesRange = 1...30

    public init(workMinutes: Int = PomodoroSettings.defaultWorkMinutes,
                breakMinutes: Int = PomodoroSettings.defaultBreakMinutes) {
        self.workMinutes = workMinutes.clamped(to: Self.workMinutesRange)
        self.breakMinutes = breakMinutes.clamped(to: Self.breakMinutesRange)
    }

    public var workSeconds: TimeInterval { TimeInterval(workMinutes * 60) }
    public var breakSeconds: TimeInterval { TimeInterval(breakMinutes * 60) }
}

/// 一次专注开始前定好的计划：模式 + 可选的「专注 N 分钟」目标
public struct SessionPlan: Equatable, Codable, Sendable {
    public var mode: SessionMode
    public var pomodoro: PomodoroSettings
    /// 本次目标：专注（分数 ≥ 70）满多少分钟。nil = 不设目标
    public var goalMinutes: Int?

    /// 设置页可选的目标（0 = 关）
    public static let goalChoices = [0, 15, 25, 45, 60, 90]

    public init(mode: SessionMode = .free, pomodoro: PomodoroSettings = PomodoroSettings(), goalMinutes: Int? = nil) {
        self.mode = mode
        self.pomodoro = pomodoro
        self.goalMinutes = (goalMinutes ?? 0) > 0 ? goalMinutes : nil
    }
}

/// 番茄钟计时：纯函数「开始时间 + 现在 → 当前在第几轮的工作 / 休息、还剩多久」，
/// 加一个记住上一次状态的 `update`，用来发现「刚切换」（震动提示）。
///
/// 用墙上时间（Date）而不是数 tick：手表放下手腕时 Timer 可能被系统推迟，数 tick 会越走越慢；
/// 按时间算，醒来那一刻就能直接算出正确的阶段。测试用假时钟喂 Date。
public struct PomodoroTimer: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case work
        case rest
    }

    public struct Phase: Equatable, Sendable {
        public let kind: Kind
        /// 第几轮（从 1 开始）。第 n 轮 = 第 n 个工作段 + 它后面的休息段
        public let cycle: Int
        /// 这一段从开始后第几秒开始、到第几秒结束
        public let startsAt: TimeInterval
        public let endsAt: TimeInterval

        public func remaining(at elapsed: TimeInterval) -> TimeInterval { max(0, endsAt - elapsed) }
    }

    public enum Event: Equatable, Sendable {
        case breakStarted(cycle: Int)
        case workStarted(cycle: Int)
    }

    public let start: Date
    public let settings: PomodoroSettings
    public private(set) var current: Phase

    public init(start: Date, settings: PomodoroSettings = PomodoroSettings()) {
        self.start = start
        self.settings = settings
        self.current = Self.phase(atElapsed: 0, settings: settings)
    }

    public static func phase(atElapsed elapsed: TimeInterval, settings: PomodoroSettings) -> Phase {
        let cycleLength = settings.workSeconds + settings.breakSeconds
        let t = max(0, elapsed)
        let index = Int(t / cycleLength)            // 0-based
        let cycleStart = TimeInterval(index) * cycleLength
        let workEnd = cycleStart + settings.workSeconds
        if t < workEnd {
            return Phase(kind: .work, cycle: index + 1, startsAt: cycleStart, endsAt: workEnd)
        }
        return Phase(kind: .rest, cycle: index + 1, startsAt: workEnd, endsAt: cycleStart + cycleLength)
    }

    public func phase(at now: Date) -> Phase {
        Self.phase(atElapsed: now.timeIntervalSince(start), settings: settings)
    }

    /// 推进到 now，返回发生的切换。
    /// 如果手表睡了很久、一次跨过好几段，只返回最后一次切换：醒来只震一下，而不是连震好几下。
    public mutating func update(now: Date) -> Event? {
        let next = phase(at: now)
        guard next != current else { return nil }
        current = next
        switch next.kind {
        case .rest: return .breakStarted(cycle: next.cycle)
        case .work: return .workStarted(cycle: next.cycle)
        }
    }
}

/// 目标结果（结束页用）
public struct GoalResult: Equatable, Sendable {
    public let goalMinutes: Int
    public let focusedMinutes: Int
    public var met: Bool { focusedMinutes >= goalMinutes }
    /// 0…1，给进度环用
    public var progress: Double { goalMinutes > 0 ? min(1, Double(focusedMinutes) / Double(goalMinutes)) : 0 }

    public init(goalMinutes: Int, focusedMinutes: Int) {
        self.goalMinutes = goalMinutes
        self.focusedMinutes = focusedMinutes
    }
}

extension SessionStats {
    /// 「专注」= 这一秒的分数 ≥ threshold（和「心流占比」同一个定义）
    public static let focusThreshold = 70.0

    /// 专注了多少秒（样本每秒一条）
    public static func focusedSeconds(_ samples: [FocusSample], threshold: Double = focusThreshold) -> Int {
        samples.filter { ($0.score ?? -1) >= threshold }.count
    }

    /// 专注分钟数（向下取整，目标按这个算）
    public static func focusedMinutes(_ samples: [FocusSample], threshold: Double = focusThreshold) -> Int {
        focusedSeconds(samples, threshold: threshold) / 60
    }

    /// 最长连续专注（秒）：连续多少条样本分数 ≥ threshold。
    /// 离座、休息、校准（没有分数）都会打断连续。
    public static func longestFocusStreak(_ samples: [FocusSample], threshold: Double = focusThreshold) -> Int {
        var best = 0, run = 0
        for s in samples {
            if let score = s.score, score >= threshold {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
        return best
    }

    public static func goalResult(_ samples: [FocusSample], goalMinutes: Int?) -> GoalResult? {
        guard let goal = goalMinutes, goal > 0 else { return nil }
        return GoalResult(goalMinutes: goal, focusedMinutes: focusedMinutes(samples))
    }
}
