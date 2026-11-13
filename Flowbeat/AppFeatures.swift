import Foundation
import FlowbeatCore

/// 这个 build 打开了哪些功能。编译条件 FLOWBEAT_AI 只在 Debug 配置里有（见 project.yml）。
///
/// - Release（上架 v1）：`FeatureFlags.offline`，没有 AI 判断、没有网络请求，数据只在手表上。
/// - Debug：AI 判断打开，窗口摘要每 2 分钟发给本机后端（AIJudge.swift）。
enum AppFeatures {
    #if FLOWBEAT_AI
    static let flags = FeatureFlags(aiJudge: true)
    #else
    static let flags = FeatureFlags.offline
    #endif

    /// 唯一构造网络客户端的地方，并且要经过开关。AI 关闭的 build 里这里永远返回 nil，HTTP 客户端的类型都不存在。
    static func makeTransport() -> (any JudgeTransport)? {
        flags.judgeTransport {
            #if FLOWBEAT_AI
            return HTTPJudgeTransport()
            #else
            return nil
            #endif
        }
    }

    /// 多久让 AI 判断一次（秒）。模拟器里缩短，方便看 demo
    #if targetEnvironment(simulator)
    static let judgeInterval: TimeInterval = 30
    #else
    static let judgeInterval: TimeInterval = 120
    #endif
}
