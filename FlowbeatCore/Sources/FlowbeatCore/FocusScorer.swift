import Foundation

/// 纯逻辑：把「心率 + 手腕动作」变成 0–100 的专注分。
/// 不依赖任何传感器，方便单独测试、以后换成训练出来的模型。
///
/// v0 规则（启发式，不是科学结论）：
/// - 前 `calibrationSeconds` 秒是校准期：收集心率，取中位数当你的「平静基线」。
/// - 动作扣分（最多 60）：手腕平均加速度越大，越可能在走神/离开座位。
/// - 心率扣分（最多 40）：心率明显高于基线，说明在紧张、兴奋或在走动。
/// - 最后做指数平滑，避免分数跳来跳去。
public struct FocusScorer {
    public var calibrationSeconds: TimeInterval

    public private(set) var baselineHR: Double?
    private var calibrationHRs: [Double] = []
    private var smoothed: Double?

    /// 平滑系数：越小越稳，越大越灵敏
    public static let alpha = 0.2

    // 阈值集中放这里，测试和 README 都引用同一组数
    public static let motionDeadZone = 0.02   // g，低于这个不扣分
    public static let motionFullPenaltyRange = 0.13  // g，从 deadZone 再加这么多扣满
    public static let motionMaxPenalty = 60.0
    public static let hrDeadZone = 5.0        // bpm，高于基线 5 以内不扣分
    public static let hrFullPenaltyRange = 15.0
    public static let hrMaxPenalty = 40.0

    public init(calibrationSeconds: TimeInterval = 60) {
        self.calibrationSeconds = calibrationSeconds
    }

    public mutating func addCalibrationHR(_ hr: Double) {
        calibrationHRs.append(hr)
    }

    /// 校准期结束时调用；没收到心率就返回 false（继续校准）
    public mutating func finishCalibration() -> Bool {
        guard !calibrationHRs.isEmpty else { return false }
        let sorted = calibrationHRs.sorted()
        baselineHR = sorted[sorted.count / 2]
        return true
    }

    /// 动作扣分：0…60
    public static func motionPenalty(_ motion: Double) -> Double {
        clamp((motion - motionDeadZone) / motionFullPenaltyRange) * motionMaxPenalty
    }

    /// 心率扣分：0…40。没有心率或还没有基线时不扣。
    public static func hrPenalty(heartRate: Double?, baseline: Double?) -> Double {
        guard let hr = heartRate, let base = baseline else { return 0 }
        return clamp((hr - base - hrDeadZone) / hrFullPenaltyRange) * hrMaxPenalty
    }

    /// 不平滑的原始分
    public static func rawScore(heartRate: Double?, motion: Double, baseline: Double?) -> Double {
        100 - motionPenalty(motion) - hrPenalty(heartRate: heartRate, baseline: baseline)
    }

    /// - Parameters:
    ///   - heartRate: 最新心率 (bpm)，可能暂时没有
    ///   - motion: 最近 10 秒手腕「用户加速度」模长的平均值 (g)
    public mutating func score(heartRate: Double?, motion: Double) -> Double {
        let raw = Self.rawScore(heartRate: heartRate, motion: motion, baseline: baselineHR)
        let next = smoothed.map { $0 + Self.alpha * (raw - $0) } ?? raw
        smoothed = next
        return next
    }

    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}

/// 固定长度的滑动平均：手表用它把 25 Hz 的加速度压成「最近 10 秒的平均动作」。
public struct RollingMean {
    public let capacity: Int
    private(set) var values: [Double] = []

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { values.count }
    public var mean: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }

    public mutating func append(_ x: Double) {
        values.append(x)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public mutating func reset() { values.removeAll() }
}
