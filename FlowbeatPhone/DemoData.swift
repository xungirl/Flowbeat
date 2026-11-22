#if targetEnvironment(simulator)
import FlowbeatCore
import FlowbeatPhoneData
import Foundation
import SwiftData

/// 模拟器截图用的示例数据（启动参数 -demoData）：过去 30 天里 22 天有专注，固定的随机种子，
/// 每次截图一样。只在内存里，不写盘，真机构建里没有这段代码。数字不是测量结果。
enum DemoData {
    static func seed(_ context: ModelContext) {
        var rng = SplitMix64(seed: 2026)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let notes = ["Thesis chapter 3", "LeetCode practice", "", "Reading papers", "Design doc", "", "Exam review"]
        for back in 0..<30 {
            guard back == 0 || rng.next() % 10 < 7,
                  let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let sessionsToday = back == 0 ? 2 : 1 + Int(rng.next() % 2)
            for i in 0..<sessionsToday {
                let hour = [9, 10, 14, 20][Int(rng.next() % 4)] + i * 2
                guard let start = cal.date(byAdding: .minute, value: hour * 60 + Int(rng.next() % 40), to: day),
                      start < Date() else { continue }
                let minutes = 20 + Int(rng.next() % 40)
                let pomodoro = rng.next() % 3 == 0
                let record = makeRecord(start: start, minutes: minutes, rng: &rng,
                                        plan: SessionPlan(mode: pomodoro ? .pomodoro : .free,
                                                          goalMinutes: pomodoro ? 25 : nil))
                guard let data = try? FlowbeatJSON.sessionEncoder.encode(record) else { continue }
                let name = ISO8601DateFormatter().string(from: start).replacingOccurrences(of: ":", with: "-")
                _ = try? SessionLibrary.upsert(name: name, data: data, into: context)
                if let s = try? SessionLibrary.sessions(named: name, in: context).first {
                    s.note = notes[Int(rng.next() % UInt64(notes.count))]
                }
            }
        }
        try? context.save()
    }

    /// 一分钟一个状态：大部分专注，偶尔走神，偶尔起身
    private static func makeRecord(start: Date, minutes: Int, rng: inout SplitMix64, plan: SessionPlan) -> SessionRecord {
        var samples: [FocusSample] = []
        var t = start
        for m in 0..<minutes {
            let roll = rng.next() % 10
            let state = m == 0 ? 0 : (roll < 7 ? 1 : (roll < 9 ? 2 : 3))   // 0 校准 1 专注 2 走神 3 离座
            for sec in 0..<60 {
                let score: Double? = switch state {
                case 1: 78 + Double(rng.next() % 20)
                case 2: 35 + Double(rng.next() % 25)
                default: nil
                }
                let label: String? = sec == 30 && rng.next() % 12 == 0 ? (state == 2 ? "distracted" : "focused") : nil
                samples.append(FocusSample(t: t, heartRate: 68 + Double(rng.next() % 12),
                                           motion: state == 1 ? 0.01 : 0.12, score: score, label: label,
                                           away: state == 3))
                t = t.addingTimeInterval(1)
            }
        }
        return SessionRecord(samples: samples, windows: [], judgments: [], review: nil, plan: plan)
    }
}

/// 固定种子的伪随机数（系统的随机数不能设种子）
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
