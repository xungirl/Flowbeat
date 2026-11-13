import Foundation

// 功能开关（feature flags）。
//
// v1 上架版是「纯本地、不联网」：AI 判断（后端 + 大模型）只在 Debug 配置里编译。
// 真正的开关是编译条件 FLOWBEAT_AI（project.yml 里只给 Debug 配置），关掉时手表 app 里连
// HTTP 客户端的代码都没有（AIJudge.swift 整个文件被 #if 掉，scripts/verify_release_offline.sh 检查二进制）。
//
// 这里是运行时的第二道闸：app 只能通过 `FeatureFlags.judgeTransport(_:)` 拿到网络客户端，
// 开关关着时工厂闭包根本不会被调用，所以即使以后有人把客户端代码编进了 Release，也不会构造、不会发请求。
// 这一层是纯逻辑，可以在 FlowbeatCore 里单元测试（FeatureFlagsTests）。

/// 发判断 / 复盘请求的「传输层」。手表 app 里的实现是 HTTPJudgeTransport（只在 FLOWBEAT_AI 时编译）。
public protocol JudgeTransport: Sendable {
    func judge(_ request: JudgeRequest) async throws -> Judgment
    func review(_ request: ReviewRequest) async throws -> Review
}

public struct FeatureFlags: Equatable, Sendable {
    /// 每 2 分钟把窗口摘要发给后端的大模型做第二意见 + 结束时的 AI 复盘
    public var aiJudge: Bool

    public init(aiJudge: Bool) {
        self.aiJudge = aiJudge
    }

    /// v1 上架版：全部本地，不联网
    public static let offline = FeatureFlags(aiJudge: false)

    /// 开关打开时才调用工厂；关着时返回 nil 且不调用工厂（不构造客户端 = 不可能发请求）。
    public func judgeTransport(_ make: () -> (any JudgeTransport)?) -> (any JudgeTransport)? {
        guard aiJudge else { return nil }
        return make()
    }
}

extension JudgeSync {
    /// 用一个传输层建发送队列
    public init(transport: any JudgeTransport, queue: OfflineQueue<JudgeRequest> = OfflineQueue(),
                now: @escaping @Sendable () -> Date = { Date() },
                onChange: (@Sendable (OfflineQueue<JudgeRequest>) -> Void)? = nil) {
        self.init(queue: queue, now: now, onChange: onChange, send: { try await transport.judge($0) })
    }
}
