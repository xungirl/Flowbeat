import XCTest
@testable import FlowbeatCore

/// 记录被调用了几次的传输层
final class CountingTransport: JudgeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _judgeCalls = 0
    private var _reviewCalls = 0
    var judgeCalls: Int { lock.lock(); defer { lock.unlock() }; return _judgeCalls }
    var reviewCalls: Int { lock.lock(); defer { lock.unlock() }; return _reviewCalls }

    func judge(_ request: JudgeRequest) async throws -> Judgment {
        lock.lock(); _judgeCalls += 1; lock.unlock()
        return Judgment(state: "focused", score: 80, reason: "ok", source: "llm")
    }

    func review(_ request: ReviewRequest) async throws -> Review {
        lock.lock(); _reviewCalls += 1; lock.unlock()
        return Review(summary: "s", tip: "t")
    }
}

final class FeatureFlagsTests: XCTestCase {
    func testReleaseDefaultIsOffline() {
        XCTAssertFalse(FeatureFlags.offline.aiJudge)
    }

    func testAIOffNeverConstructsTheJudgeClient() {
        var constructed = 0
        let transport = FeatureFlags.offline.judgeTransport {
            constructed += 1
            return CountingTransport()
        }
        XCTAssertNil(transport)
        XCTAssertEqual(constructed, 0, "with the AI flag off the network client must not even be built")
    }

    func testAIOnConstructsTheClientOnce() {
        var constructed = 0
        let transport = FeatureFlags(aiJudge: true).judgeTransport {
            constructed += 1
            return CountingTransport()
        }
        XCTAssertNotNil(transport)
        XCTAssertEqual(constructed, 1)
    }

    func testAIOnWithoutACompiledClientFailsClosed() {
        // Debug 配置打开了开关，但这个 build 没编译客户端（工厂返回 nil）：不联网，而不是崩溃
        XCTAssertNil(FeatureFlags(aiJudge: true).judgeTransport { nil })
    }

    func testJudgeSyncSendsThroughTheTransport() async {
        let t = CountingTransport()
        let sync = JudgeSync(transport: t)
        let r = await sync.submit(JudgeRequest(
            window: WindowSummary(minuteOfSession: 2, localTime: "10:00", motionMean: 0, motionMax: 0,
                                  stillRatio: 1, awaySeconds: 0),
            examples: [], recent: []))
        XCTAssertEqual(r.delivered.count, 1)
        XCTAssertEqual(t.judgeCalls, 1)
    }
}
