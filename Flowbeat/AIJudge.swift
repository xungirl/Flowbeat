import Foundation
import FlowbeatCore

// 数据格式（WindowSummary / Judgment / LabeledExample / Review / 请求体）都在 FlowbeatCore/Models.swift，
// 这里只放和网络、存储有关的部分。

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
    private static let encoder = FlowbeatJSON.encoder
    private static let decoder = FlowbeatJSON.decoder

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
        let list = LabeledExample.appending(example, to: examples, maxCount: maxCount)
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
