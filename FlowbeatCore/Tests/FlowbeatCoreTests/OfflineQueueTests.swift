import XCTest
@testable import FlowbeatCore

/// 可以手动拨动的时钟
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_794_493_800)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}

/// 假后端：online 控制成功/失败，记录收到的请求顺序
final class FakeBackend: @unchecked Sendable {
    private let lock = NSLock()
    var online = true
    var failWith: Error = URLError(.notConnectedToInternet)
    var delayNanos: UInt64 = 0
    private(set) var received: [Int] = []   // minuteOfSession

    func send(_ r: JudgeRequest) async throws -> Judgment {
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        lock.lock(); defer { lock.unlock() }
        received.append(r.window.minuteOfSession)
        guard online else { throw failWith }
        return Judgment(state: "focused", score: 80, reason: "m\(r.window.minuteOfSession)", source: "llm")
    }
}

private func req(_ minute: Int) -> JudgeRequest {
    JudgeRequest(window: WindowSummary(minuteOfSession: minute, localTime: "10:00", motionMean: 0.01, motionMax: 0.02,
                                       stillRatio: 1, awaySeconds: 0), examples: [], recent: [])
}

final class RetryPolicyTests: XCTestCase {
    func testExponentialBackoffWithCap() {
        let p = RetryPolicy(baseDelay: 15, multiplier: 2, maxDelay: 300)
        XCTAssertEqual((0...7).map { p.delay(afterFailures: $0) }, [0, 15, 30, 60, 120, 240, 300, 300])
    }

    func testHTTPErrorClassification() {
        XCTAssertTrue(HTTPStatusError(code: 422).isPermanent)
        XCTAssertTrue(HTTPStatusError(code: 401).isPermanent)
        XCTAssertFalse(HTTPStatusError(code: 429).isPermanent)
        XCTAssertFalse(HTTPStatusError(code: 408).isPermanent)
        XCTAssertFalse(HTTPStatusError(code: 502).isPermanent)
    }
}

final class OfflineQueueTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 0)

    func testCapacityDropsOldest() {
        var q = OfflineQueue<Int>(capacity: 3)
        for i in 1...3 { XCTAssertEqual(q.enqueue(i, at: t0), []) }
        XCTAssertEqual(q.enqueue(4, at: t0), [1])
        XCTAssertEqual(q.entries.map(\.item), [2, 3, 4])
        XCTAssertEqual(q.droppedCount, 1)
    }

    func testExpireDropsOldEntries() {
        var q = OfflineQueue<Int>(capacity: 10, maxAge: 600)
        q.enqueue(1, at: t0)
        q.enqueue(2, at: t0 + 500)
        XCTAssertEqual(q.expire(at: t0 + 601), 1)
        XCTAssertEqual(q.entries.map(\.item), [2])
    }

    func testTransientFailureBlocksWholeQueueWithGrowingBackoff() {
        var q = OfflineQueue<Int>(policy: RetryPolicy(baseDelay: 10, multiplier: 2, maxDelay: 100))
        q.enqueue(1, at: t0)
        let id = q.head!.id
        q.recordTransientFailure(id: id, at: t0)
        XCTAssertEqual(q.nextAttemptAt, t0 + 10)
        XCTAssertTrue(q.isBlocked(at: t0 + 9))
        XCTAssertFalse(q.isBlocked(at: t0 + 10))
        q.recordTransientFailure(id: id, at: t0 + 10)
        XCTAssertEqual(q.nextAttemptAt, t0 + 30)   // +20
        q.recordSuccess(id: id)
        XCTAssertNil(q.nextAttemptAt)
        XCTAssertEqual(q.consecutiveFailures, 0)
        XCTAssertTrue(q.isEmpty)
    }

    func testPoisonItemIsDroppedAfterMaxAttempts() {
        var q = OfflineQueue<Int>(policy: RetryPolicy(maxAttempts: 3))
        q.enqueue(1, at: t0)
        q.enqueue(2, at: t0)
        let id = q.head!.id
        XCTAssertTrue(q.recordTransientFailure(id: id, at: t0))
        XCTAssertTrue(q.recordTransientFailure(id: id, at: t0))
        XCTAssertFalse(q.recordTransientFailure(id: id, at: t0))
        XCTAssertEqual(q.entries.map(\.item), [2])
        XCTAssertEqual(q.droppedCount, 1)
    }

    func testQueueIsCodable() throws {
        var q = OfflineQueue<JudgeRequest>(capacity: 5)
        q.enqueue(req(2), at: t0)
        let back = try JSONDecoder().decode(OfflineQueue<JudgeRequest>.self, from: JSONEncoder().encode(q))
        XCTAssertEqual(back, q)
    }
}

final class JudgeSyncTests: XCTestCase {

    private func make(_ backend: FakeBackend, _ clock: TestClock, capacity: Int = 30) -> JudgeSync {
        JudgeSync(queue: OfflineQueue(capacity: capacity, policy: RetryPolicy(baseDelay: 15, multiplier: 2, maxDelay: 300)),
                  now: { clock.now }, send: { try await backend.send($0) })
    }

    func testOnlineSubmitIsDeliveredImmediately() async {
        let b = FakeBackend(), c = TestClock()
        let sync = make(b, c)
        let r = await sync.submit(req(2))
        XCTAssertEqual(r.delivered.map(\.judgment.reason), ["m2"])
        XCTAssertEqual(r.pending, 0)
    }

    func testOfflineQueuesAndDoesNotRetryDuringBackoff() async {
        let b = FakeBackend(), c = TestClock()
        b.online = false
        let sync = make(b, c)
        let r1 = await sync.submit(req(2))
        XCTAssertTrue(r1.delivered.isEmpty)
        XCTAssertEqual(r1.pending, 1)
        XCTAssertNotNil(r1.lastError)

        c.advance(5)    // 还在 15 s 退避期内
        let r2 = await sync.submit(req(4))
        XCTAssertEqual(r2.pending, 2)
        XCTAssertEqual(b.received, [2], "no network call while backing off (saves battery)")
    }

    func testBacklogIsDeliveredInOrderWhenBackendReturns() async {
        let b = FakeBackend(), c = TestClock()
        b.online = false
        let sync = make(b, c)
        _ = await sync.submit(req(2))
        c.advance(5); _ = await sync.submit(req(4))
        c.advance(5); _ = await sync.submit(req(6))

        b.online = true
        c.advance(10)   // 过了 15 s 退避
        let r = await sync.flush()
        XCTAssertEqual(r.delivered.map(\.request.window.minuteOfSession), [2, 4, 6])
        XCTAssertEqual(r.pending, 0)
        let q = await sync.queue
        XCTAssertNil(q.nextAttemptAt)
    }

    func testBackoffGrowsAcrossConsecutiveFailedFlushes() async {
        let b = FakeBackend(), c = TestClock()
        b.online = false
        let sync = make(b, c)
        _ = await sync.submit(req(2))           // fail #1 → +15
        var q = await sync.queue
        XCTAssertEqual(q.nextAttemptAt, c.now + 15)
        c.advance(15); _ = await sync.flush()   // fail #2 → +30
        q = await sync.queue
        XCTAssertEqual(q.nextAttemptAt, c.now + 30)
        c.advance(30); _ = await sync.flush()   // fail #3 → +60
        q = await sync.queue
        XCTAssertEqual(q.nextAttemptAt, c.now + 60)
        XCTAssertEqual(b.received, [2, 2, 2])
    }

    func testQueueCapDuringLongOutage() async {
        let b = FakeBackend(), c = TestClock()
        b.online = false
        let sync = make(b, c, capacity: 5)
        for m in stride(from: 2, through: 40, by: 2) {   // 20 个窗口 = 40 分钟断网
            _ = await sync.submit(req(m))
            c.advance(120)
        }
        let q = await sync.queue
        XCTAssertEqual(q.count, 5)
        XCTAssertEqual(q.entries.map(\.item.window.minuteOfSession), [32, 34, 36, 38, 40], "keeps the newest windows")
    }

    func testPermanentErrorDropsItemWithoutBlocking() async {
        let b = FakeBackend(), c = TestClock()
        b.online = false
        b.failWith = HTTPStatusError(code: 422)
        let sync = make(b, c)
        let r = await sync.submit(req(2))
        XCTAssertEqual(r.droppedPermanent, 1)
        XCTAssertEqual(r.pending, 0)
        let q = await sync.queue
        XCTAssertFalse(q.isBlocked(at: c.now), "a bad payload must not put the whole queue into backoff")
    }

    func testFinalFlushIgnoresBackoff() async {
        let b = FakeBackend(), c = TestClock()
        b.online = false
        let sync = make(b, c)
        _ = await sync.submit(req(2))
        b.online = true
        let blocked = await sync.flush()
        XCTAssertTrue(blocked.delivered.isEmpty, "still in backoff")
        let final = await sync.flush(ignoringBackoff: true)
        XCTAssertEqual(final.delivered.count, 1)
    }

    func testConcurrentSubmitsNeverSendTheSameWindowTwice() async {
        let b = FakeBackend(), c = TestClock()
        b.delayNanos = 30_000_000   // 每次请求 30 ms，让两个 submit 交错
        let sync = make(b, c)
        async let r1 = sync.submit(req(2))
        async let r2 = sync.submit(req(4))
        let (a, d) = await (r1, r2)
        XCTAssertEqual(b.received.sorted(), [2, 4])
        XCTAssertEqual(a.delivered.count + d.delivered.count, 2)
    }
}
