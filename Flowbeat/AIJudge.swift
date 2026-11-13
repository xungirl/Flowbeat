// 整个文件只在 FLOWBEAT_AI 编译条件下存在（project.yml：只有 Debug 配置有）。
// Release（上架版）里没有后端地址、口令、HTTP 客户端，也没有 few-shot 标注存储。
// scripts/verify_release_offline.sh 会检查 Release 二进制里确实没有这些字符串。
#if FLOWBEAT_AI
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
}

// MARK: - 网络

/// FeatureFlags.judgeTransport 的唯一实现。只能经过开关构造（见 AppFeatures.makeTransport）。
struct HTTPJudgeTransport: JudgeTransport {
    private static let encoder = FlowbeatJSON.encoder
    private static let decoder = FlowbeatJSON.decoder

    /// 失败时抛 HTTPStatusError（后端返回非 200）或 URLError（连不上 / 超时），JudgeSync 据此决定丢弃还是排队重试
    func judge(_ req: JudgeRequest) async throws -> Judgment {
        try await post("/v1/judge", req)
    }

    func review(_ req: ReviewRequest) async throws -> Review {
        try await post("/v1/review", req)
    }

    private func post<In: Encodable, Out: Decodable>(_ path: String, _ body: In) async throws -> Out {
        var r = URLRequest(url: AIConfig.baseURL.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = AIConfig.token { r.setValue(t, forHTTPHeaderField: "X-Flowbeat-Token") }
        r.httpBody = try Self.encoder.encode(body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw HTTPStatusError(code: http.statusCode) }
        return try Self.decoder.decode(Out.self, from: data)
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
#endif
