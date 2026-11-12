import Foundation

// 手表 ↔ 后端的数据格式，和 backend/app/schemas.py 一一对应。
// JSON 用 snake_case（编码器自动把 hrMean 转成 hr_mean）。

struct WindowSummary: Codable {
    var minuteOfSession: Int
    var localTime: String
    var baselineHr: Double?
    var hrMean: Double?
    var hrMin: Double?
    var hrMax: Double?
    var hrTrend: Double?
    var motionMean: Double
    var motionMax: Double
    var stillRatio: Double
    var awaySeconds: Int
    var ruleScoreMean: Double?

    /// 把一段逐秒样本压缩成摘要：只发统计量，不发原始数据，省流量也更好让模型理解
    static func make(from samples: [FocusSample], baseline: Double?, sessionStart: Date) -> WindowSummary {
        let hrs = samples.compactMap(\.heartRate)
        let motions = samples.map(\.motion)
        let scores = samples.compactMap(\.score)
        let end = samples.last?.t ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return WindowSummary(
            minuteOfSession: Int(end.timeIntervalSince(sessionStart) / 60),
            localTime: fmt.string(from: end),
            baselineHr: baseline.map(round1),
            hrMean: hrs.isEmpty ? nil : round1(hrs.reduce(0, +) / Double(hrs.count)),
            hrMin: hrs.min().map(round1),
            hrMax: hrs.max().map(round1),
            hrTrend: (hrs.first != nil && hrs.last != nil) ? round1(hrs.last! - hrs.first!) : nil,
            motionMean: round3(motions.isEmpty ? 0 : motions.reduce(0, +) / Double(motions.count)),
            motionMax: round3(motions.max() ?? 0),
            stillRatio: round3(motions.isEmpty ? 0 : Double(motions.filter { $0 < 0.03 }.count) / Double(motions.count)),
            awaySeconds: samples.filter(\.away).count,
            ruleScoreMean: scores.isEmpty ? nil : round1(scores.reduce(0, +) / Double(scores.count))
        )
    }
}

private func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
private func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

struct Judgment: Codable, Equatable {
    var state: String   // focused / distracted / away / unclear
    var score: Int
    var reason: String
}

struct LabeledExample: Codable {
    var window: WindowSummary
    var label: String   // focused / distracted
}

struct Review: Codable {
    var summary: String
    var tip: String
}

private struct JudgeRequest: Codable {
    var window: WindowSummary
    var examples: [LabeledExample]
    var recent: [Judgment]
}

struct ReviewRequest: Codable {
    var durationMinutes: Int
    var averageScore: Double?
    var focusedRatio: Double?
    var awayCount: Int
    var awayMinutes: Double
    var windows: [WindowSummary]
    var judgments: [Judgment]
}

// MARK: - 配置

enum AIConfig {
    #if targetEnvironment(simulator)
    /// 模拟器和 Mac 共用网络，直接连本机后端
    static let baseURL = URL(string: "http://localhost:8765")!
    #else
    /// 真手表：改成你 Mac 的局域网名字（终端运行 `scutil --get LocalHostName`，后面加 .local），
    /// 手表和 Mac 要在同一个 Wi-Fi。以后部署到 Cloud Run 就换成 https 地址。
    static let baseURL = URL(string: "http://YOUR-MAC.local:8765")!
    #endif
    /// 后端设置了 FLOWBEAT_TOKEN 时，这里填同一个值
    static let token: String? = nil
    /// 多久让 AI 判断一次（秒）。模拟器里缩短，方便看 demo
    #if targetEnvironment(simulator)
    static let judgeInterval: TimeInterval = 30
    #else
    static let judgeInterval: TimeInterval = 120
    #endif
}

// MARK: - 网络

enum AIClient {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func judge(window: WindowSummary, recent: [Judgment]) async throws -> Judgment {
        let req = JudgeRequest(window: window, examples: LabelStore.examples, recent: Array(recent.suffix(3)))
        return try await post("/v1/judge", req)
    }

    static func review(_ req: ReviewRequest) async throws -> Review {
        try await post("/v1/review", req)
    }

    private static func post<In: Encodable, Out: Decodable>(_ path: String, _ body: In) async throws -> Out {
        var r = URLRequest(url: AIConfig.baseURL.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = AIConfig.token { r.setValue(t, forHTTPHeaderField: "X-Flowbeat-Token") }
        r.httpBody = try encoder.encode(body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(Out.self, from: data)
    }
}

// MARK: - 你的标注例子（跨次保存，最多 20 条，作为 few-shot 发给模型）

enum LabelStore {
    private static let key = "labeledExamples"
    private static let maxCount = 20

    static var examples: [LabeledExample] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([LabeledExample].self, from: data) else { return [] }
        return list
    }

    static func add(_ example: LabeledExample) {
        var list = examples
        list.append(example)
        if list.count > maxCount { list.removeFirst(list.count - maxCount) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
