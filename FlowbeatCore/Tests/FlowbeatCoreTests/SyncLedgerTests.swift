import XCTest
@testable import FlowbeatCore

final class SyncLedgerTests: XCTestCase {
    func testPendingSkipsDeliveredAndInFlightOldestFirst() {
        var ledger = SyncLedger()
        let archive = ["2027-01-03T09-00-00Z", "2027-01-01T09-00-00Z", "2027-01-02T09-00-00Z"]
        XCTAssertEqual(ledger.pending(archive: archive, inFlight: []),
                       ["2027-01-01T09-00-00Z", "2027-01-02T09-00-00Z", "2027-01-03T09-00-00Z"])
        ledger.markDelivered("2027-01-01T09-00-00Z")
        XCTAssertEqual(ledger.pending(archive: archive, inFlight: ["2027-01-03T09-00-00Z"]), ["2027-01-02T09-00-00Z"])
    }

    /// iPhone 上删掉的记录不会被重传：送达过就留在账本里
    func testDeliveredStaysDeliveredUntilArchiveDeletesIt() {
        var ledger = SyncLedger(delivered: ["a", "b"])
        XCTAssertEqual(ledger.pending(archive: ["a", "b"], inFlight: []), [])
        ledger.prune(keeping: ["b", "c"])
        XCTAssertEqual(ledger.delivered, ["b"])
        XCTAssertEqual(ledger.pending(archive: ["b", "c"], inFlight: []), ["c"])
    }

    func testLedgerRoundTripsThroughDefaults() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "SyncLedgerTests-\(UUID())"))
        XCTAssertEqual(SyncLedger.load(from: d), SyncLedger())
        SyncLedger(delivered: ["x", "y"]).save(to: d)
        XCTAssertEqual(SyncLedger.load(from: d).delivered, ["x", "y"])
    }

    func testSharedSettingsNewerWinsAndClamps() throws {
        let old = SharedSettings(dailyGoalMinutes: 60, updatedAt: Date(timeIntervalSince1970: 100))
        let new = SharedSettings(dailyGoalMinutes: 90, updatedAt: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(new.shouldReplace(old))
        XCTAssertFalse(old.shouldReplace(new))
        XCTAssertFalse(old.shouldReplace(old))
        XCTAssertTrue(old.shouldReplace(nil))
        XCTAssertEqual(SharedSettings(dailyGoalMinutes: 5000, updatedAt: .now).dailyGoalMinutes,
                       FocusHistory.dailyGoalRange.upperBound)

        let back = try XCTUnwrap(SharedSettings(context: new.context))
        XCTAssertEqual(back, new)
        XCTAssertNil(SharedSettings(context: ["dailyGoalMinutes": "90"]))
    }

    func testSharedSettingsUseWatchGoalKey() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "SharedSettingsTests-\(UUID())"))
        XCTAssertNil(SharedSettings.load(from: d))
        // 手表旧版本只写了 goal.dailyMinutes、没有时间：读出来时间是 1970，任何一次修改都比它新
        d.set(45, forKey: "goal.dailyMinutes")
        let legacy = try XCTUnwrap(SharedSettings.load(from: d))
        XCTAssertEqual(legacy.dailyGoalMinutes, 45)
        XCTAssertEqual(legacy.updatedAt, Date(timeIntervalSince1970: 0))
        SharedSettings(dailyGoalMinutes: 75, updatedAt: Date(timeIntervalSince1970: 300)).save(to: d)
        XCTAssertEqual(SharedSettings.load(from: d)?.dailyGoalMinutes, 75)
    }
}
