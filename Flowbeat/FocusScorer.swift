import Foundation

/// 纯逻辑：把「心率 + 手腕动作」变成 0–100 的专注分。
/// 不依赖任何传感器，方便以后单独测试、换成训练出来的模型。
///
/// v0 规则（启发式，不是科学结论）：
/// - 前 `calibrationSeconds` 秒是校准期：收集心率，取中位数当你的「平静基线」。
/// - 动作扣分（最多 60）：手腕平均加速度越大，越可能在走神/离开座位。
/// - 心率扣分（最多 40）：心率明显高于基线，说明在紧张、兴奋或在走动。
/// - 最后做指数平滑，避免分数跳来跳去。
struct FocusScorer {
    var calibrationSeconds: TimeInterval = 60

    private(set) var baselineHR: Double?
    private var calibrationHRs: [Double] = []
    private var smoothed: Double?

    /// 平滑系数：越小越稳，越大越灵敏
    private let alpha = 0.2

    mutating func addCalibrationHR(_ hr: Double) {
        calibrationHRs.append(hr)
    }

    /// 校准期结束时调用；没收到心率就返回 false（继续校准）
    mutating func finishCalibration() -> Bool {
        guard !calibrationHRs.isEmpty else { return false }
        let sorted = calibrationHRs.sorted()
        baselineHR = sorted[sorted.count / 2]
        return true
    }

    /// - Parameters:
    ///   - heartRate: 最新心率 (bpm)，可能暂时没有
    ///   - motion: 最近 10 秒手腕「用户加速度」模长的平均值 (g)
    mutating func score(heartRate: Double?, motion: Double) -> Double {
        let motionPenalty = clamp((motion - 0.02) / 0.13) * 60

        var hrPenalty = 0.0
        if let hr = heartRate, let base = baselineHR {
            hrPenalty = clamp((hr - base - 5) / 15) * 40
        }

        let raw = 100 - motionPenalty - hrPenalty
        let next = smoothed.map { $0 + alpha * (raw - $0) } ?? raw
        smoothed = next
        return next
    }

    private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}
