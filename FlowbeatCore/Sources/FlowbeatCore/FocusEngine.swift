import Foundation

/// 离座状态机：系统活动识别说你在走路/跑步 → away；说你静止 → 回到座位。
///
/// 规则：
/// - 只有状态真的变化才算一次切换（重复的 walking 事件不会让次数 +1）。
/// - 每次「坐 → 离座」awayCount +1。
/// - 「离座 → 坐」时记下时间，之后 `recoverySeconds` 秒内算恢复期：心率还没降下来，不按心率扣分。
public struct AwayTracker: Equatable {
    public private(set) var isAway = false
    public private(set) var awayCount = 0
    public private(set) var awaySeconds: TimeInterval = 0
    public private(set) var awayEndedAt: TimeInterval?
    public let recoverySeconds: TimeInterval

    public init(recoverySeconds: TimeInterval = 60) {
        self.recoverySeconds = recoverySeconds
    }

    /// - Returns: 状态是否真的变了
    @discardableResult
    public mutating func set(away: Bool, at elapsed: TimeInterval) -> Bool {
        guard away != isAway else { return false }
        isAway = away
        if away {
            awayCount += 1
        } else {
            awayEndedAt = elapsed
        }
        return true
    }

    /// 刚坐回来、还在心率恢复期内吗
    public func isRecovering(at elapsed: TimeInterval) -> Bool {
        guard !isAway, let end = awayEndedAt else { return false }
        return elapsed - end < recoverySeconds
    }

    mutating func addAwaySecond() { awaySeconds += 1 }
}

/// 每秒一次的打分流程，从 FocusSession 里抽出来的纯逻辑：校准 → 打分，离座时暂停。
/// FocusSession 只负责传感器和 UI，把每秒读到的数喂进来。
public struct FocusEngine {
    public enum Phase: String, Codable, Equatable {
        case calibrating, running
    }

    public struct Tick: Equatable {
        /// 这一秒存进样本的分数。校准期、离座、或刚结束校准那一秒为 nil
        public let sampleScore: Double?
        /// 这一秒刚从校准切换到打分
        public let didFinishCalibration: Bool
    }

    public private(set) var phase: Phase = .calibrating
    public private(set) var scorer: FocusScorer
    public private(set) var away: AwayTracker
    /// 圆环上显示的分数（离座时保持最后一个值）
    public private(set) var score: Double?

    public init(calibrationSeconds: TimeInterval = 60, recoverySeconds: TimeInterval = 60) {
        scorer = FocusScorer(calibrationSeconds: calibrationSeconds)
        away = AwayTracker(recoverySeconds: recoverySeconds)
    }

    public var baselineHR: Double? { scorer.baselineHR }
    public var calibrationSeconds: TimeInterval { scorer.calibrationSeconds }

    @discardableResult
    public mutating func setAway(_ isAway: Bool, at elapsed: TimeInterval) -> Bool {
        away.set(away: isAway, at: elapsed)
    }

    public mutating func tick(elapsed: TimeInterval, heartRate: Double?, motion: Double) -> Tick {
        var finished = false
        switch phase {
        case .calibrating:
            // 走动时的心率不能当「平静基线」
            if let hr = heartRate, !away.isAway { scorer.addCalibrationHR(hr) }
            if elapsed >= scorer.calibrationSeconds, scorer.finishCalibration() {
                phase = .running
                finished = true
            }
        case .running:
            if away.isAway {
                away.addAwaySecond()   // 离座：不打分，也不计入专注占比
            } else {
                let recovering = away.isRecovering(at: elapsed)
                score = scorer.score(heartRate: recovering ? nil : heartRate, motion: motion)
            }
        }
        let scored = phase == .running && !away.isAway && !finished
        return Tick(sampleScore: scored ? score : nil, didFinishCalibration: finished)
    }
}

/// 结束页的汇总数字
public enum SessionStats {
    /// 平均分（只算打过分的秒）
    public static func averageScore(_ samples: [FocusSample]) -> Double? {
        let s = samples.compactMap(\.score)
        return s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
    }

    /// 分数 ≥ threshold 的时间占比
    public static func focusedRatio(_ samples: [FocusSample], threshold: Double = 70) -> Double? {
        let s = samples.compactMap(\.score)
        return s.isEmpty ? nil : Double(s.filter { $0 >= threshold }.count) / Double(s.count)
    }
}
