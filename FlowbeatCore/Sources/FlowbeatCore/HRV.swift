import Foundation

/// 心率变异性（HRV，SDNN，单位毫秒）。
///
/// 为什么是「最近一次读数 + 距今多久」而不是「这 2 分钟的平均」：
/// Apple Watch 只在后台偶尔测 SDNN（一天几次，或做「呼吸」时），专注的 2 分钟窗口里通常一个新读数都没有。
/// 所以只能拿最近 `lookback` 内的一次读数，并把「已经过去几分钟」一起发给模型，让它自己掂量要不要参考。
/// 没有读数（没授权、没戴够时间、模拟器）就是 nil，摘要里不带这两个字段。
public struct HRVSample: Codable, Equatable, Sendable {
    public let date: Date
    public let sdnnMs: Double

    public init(date: Date, sdnnMs: Double) {
        self.date = date
        self.sdnnMs = sdnnMs
    }
}

public struct HRVReading: Equatable, Sendable {
    public let sdnnMs: Double
    public let ageMinutes: Int
}

public enum HRVSummary {
    /// SDNN 合理范围（毫秒）。范围外多半是传感器噪声
    public static let plausibleRange = 5.0...250.0
    /// 太旧的读数没参考价值
    public static let defaultLookback: TimeInterval = 6 * 3600

    /// 取窗口结束时刻之前、lookback 之内最新的一个合理读数
    public static func latest(from samples: [HRVSample], at windowEnd: Date,
                              lookback: TimeInterval = defaultLookback) -> HRVReading? {
        let candidates = samples.filter {
            $0.date <= windowEnd
                && windowEnd.timeIntervalSince($0.date) <= lookback
                && plausibleRange.contains($0.sdnnMs)
        }
        guard let s = candidates.max(by: { $0.date < $1.date }) else { return nil }
        return HRVReading(sdnnMs: round1(s.sdnnMs), ageMinutes: Int(windowEnd.timeIntervalSince(s.date) / 60))
    }
}
