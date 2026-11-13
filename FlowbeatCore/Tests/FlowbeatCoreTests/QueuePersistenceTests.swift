import XCTest
@testable import FlowbeatCore

private func req(_ minute: Int) -> JudgeRequest {
    JudgeRequest(window: WindowSummary(minuteOfSession: minute, localTime: "10:00", motionMean: 0.01, motionMax: 0.02,
                                       stillRatio: 1, awaySeconds: 0), examples: [], recent: [])
}

/// 收集 onChange 回调里最后一份队列
final class Snapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [OfflineQueue<JudgeRequest>] = []
    func add(_ q: OfflineQueue<JudgeRequest>) { lock.lock(); _all.append(q); lock.unlock() }
    var all: [OfflineQueue<JudgeRequest>] { lock.lock(); defer { lock.unlock() }; return _all }
}

final class QueuePersistenceTests: XCTestCase {
    var dir: URL!
    let t0 = Date(timeIntervalSince1970: 1_794_493_800)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-queue-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSaveAndLoadRoundTripKeepsOrderTimesAndAttempts() throws {
        let store = JudgeQueueStore(directory: dir)
        var q = OfflineQueue<JudgeRequest>()
        q.enqueue(req(2), at: t0)
        q.enqueue(req(4), at: t0 + 120)
        q.recordTransientFailure(id: q.head!.id, at: t0 + 130)
        try store.save(q, session: "s1")

        let back = try XCTUnwrap(store.load(session: "s1", at: t0 + 200))
        XCTAssertEqual(back.entries.map(\.item.window.minuteOfSession), [2, 4])
        XCTAssertEqual(back.entries.map(\.enqueuedAt), [t0, t0 + 120])
        XCTAssertEqual(back.entries.map(\.attempts), [1, 0])
        XCTAssertNil(back.nextAttemptAt, "backoff is cleared after a relaunch: try once right away")
    }

    func testLoadDropsEntriesOlderThanOneHour() throws {
        let store = JudgeQueueStore(directory: dir)
        var q = OfflineQueue<JudgeRequest>()
        q.enqueue(req(2), at: t0)
        q.enqueue(req(4), at: t0 + 1800)
        try store.save(q, session: "s1")
        let back = try XCTUnwrap(store.load(session: "s1", at: t0 + 3601))
        XCTAssertEqual(back.entries.map(\.item.window.minuteOfSession), [4])
        XCTAssertEqual(back.maxAge, 3600)
    }

    func testLoadAppliesTheCurrentCapacityNotTheSavedOne() throws {
        // 文件是旧版本用容量 50 存的：读回来按现在的 30 截断，保留最新的
        var big = OfflineQueue<JudgeRequest>(capacity: 50)
        for m in 1...40 { big.enqueue(req(m), at: t0) }
        try JSONFileStore<OfflineQueue<JudgeRequest>>(url: dir.appendingPathComponent("old.json")).save(big)
        let back = try XCTUnwrap(JudgeQueueStore(directory: dir).load(session: "old", at: t0))
        XCTAssertEqual(back.capacity, 30)
        XCTAssertEqual(back.count, 30)
        XCTAssertEqual(back.entries.first?.item.window.minuteOfSession, 11)
        XCTAssertEqual(back.entries.last?.item.window.minuteOfSession, 40)
    }

    func testFullyExpiredFileIsDeletedOnLoad() throws {
        let store = JudgeQueueStore(directory: dir)
        var q = OfflineQueue<JudgeRequest>()
        q.enqueue(req(2), at: t0)
        try store.save(q, session: "s1")
        XCTAssertNil(store.load(session: "s1", at: t0 + 7200))
        XCTAssertEqual(store.sessions(), [])
    }

    func testSavingAnEmptyQueueRemovesTheFile() throws {
        let store = JudgeQueueStore(directory: dir)
        var q = OfflineQueue<JudgeRequest>()
        q.enqueue(req(2), at: t0)
        try store.save(q, session: "s1")
        XCTAssertEqual(store.sessions(), ["s1"])
        q.recordSuccess(id: q.head!.id)
        try store.save(q, session: "s1")
        XCTAssertEqual(store.sessions(), [])
    }

    func testCorruptFileIsMovedAsideAndTreatedAsEmpty() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("bad.json")
        try Data("{not json".utf8).write(to: url)
        let store = JudgeQueueStore(directory: dir)
        XCTAssertNil(store.load(session: "bad"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
        XCTAssertEqual(store.sessions(), [], "the corrupt file no longer counts as a pending session")
    }

    func testSessionNameCannotEscapeTheDirectory() throws {
        let store = JudgeQueueStore(directory: dir)
        var q = OfflineQueue<JudgeRequest>()
        q.enqueue(req(2), at: t0)
        try store.save(q, session: "../../escape")
        XCTAssertEqual(store.sessions(), ["escape"])
    }

    func testAtomicWriteLeavesNoTemporaryFiles() throws {
        let store = JudgeQueueStore(directory: dir)
        var q = OfflineQueue<JudgeRequest>()
        for m in 1...5 {
            q.enqueue(req(m), at: t0)
            try store.save(q, session: "s1")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files, ["s1.json"])
    }

    // MARK: - JudgeSync + 落盘

    func testJudgeSyncReportsEveryChangeAndSurvivesARelaunch() async throws {
        let store = JudgeQueueStore(directory: dir)
        let backend = FakeBackend(), clock = TestClock()
        backend.online = false
        let snaps = Snapshots()
        let sync = JudgeSync(queue: OfflineQueue(), now: { clock.now },
                             onChange: { q in snaps.add(q); try? store.save(q, session: "s1") },
                             send: { try await backend.send($0) })
        _ = await sync.submit(req(2))
        clock.advance(5); _ = await sync.submit(req(4))
        XCTAssertEqual(snaps.all.last?.count, 2)

        // 「app 被杀掉」：丢掉 sync，从磁盘重建
        let restored = try XCTUnwrap(store.load(session: "s1", at: clock.now))
        backend.online = true
        let sync2 = JudgeSync(queue: restored, now: { clock.now },
                              onChange: { q in try? store.save(q, session: "s1") },
                              send: { try await backend.send($0) })
        let r = await sync2.flush()
        XCTAssertEqual(r.delivered.map(\.request.window.minuteOfSession), [2, 4], "in order after relaunch")
        XCTAssertEqual(store.sessions(), [], "file removed once everything is delivered")
    }

    func testPermanentDropIsPersistedToo() async throws {
        let store = JudgeQueueStore(directory: dir)
        let backend = FakeBackend()
        backend.online = false
        backend.failWith = HTTPStatusError(code: 422)
        let sync = JudgeSync(onChange: { q in try? store.save(q, session: "s1") }, send: { try await backend.send($0) })
        _ = await sync.submit(req(2))
        XCTAssertEqual(store.sessions(), [])
    }

    // MARK: - 晚到的判断补进存档

    func testLateJudgmentsAreAppendedToTheArchive() {
        let w = req(2).window
        let record = SessionRecord(samples: [], windows: [w], judgments: [], review: nil, timeline: nil)
        let j = Judgment(state: "focused", score: 80, reason: "late", source: "llm")
        let out = record.appendingLateJudgments([(req(2), j)])
        XCTAssertEqual(out.judgments, [j])
        XCTAssertEqual(out.windows, [w], "windows were archived when they were created; not duplicated")
        XCTAssertEqual(out.timeline, [JudgedWindow(minute: 2, judgment: j, endSeconds: nil)])
    }
}
