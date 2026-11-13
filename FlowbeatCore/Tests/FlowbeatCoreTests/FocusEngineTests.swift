import XCTest
@testable import FlowbeatCore

final class AwayTrackerTests: XCTestCase {

    func testStartsSeated() {
        let a = AwayTracker()
        XCTAssertFalse(a.isAway)
        XCTAssertEqual(a.awayCount, 0)
        XCTAssertFalse(a.isRecovering(at: 0))
    }

    func testRepeatedWalkingEventsCountOnce() {
        var a = AwayTracker()
        XCTAssertTrue(a.set(away: true, at: 10))
        XCTAssertFalse(a.set(away: true, at: 11))
        XCTAssertFalse(a.set(away: true, at: 12))
        XCTAssertEqual(a.awayCount, 1)
    }

    func testStationaryWhileSeatedIsNoOp() {
        var a = AwayTracker()
        XCTAssertFalse(a.set(away: false, at: 5))
        XCTAssertNil(a.awayEndedAt)
    }

    func testRecoveryWindowAfterSittingBackDown() {
        var a = AwayTracker(recoverySeconds: 60)
        a.set(away: true, at: 100)
        XCTAssertFalse(a.isRecovering(at: 110), "while away we are not 'recovering'")
        a.set(away: false, at: 130)
        XCTAssertTrue(a.isRecovering(at: 130))
        XCTAssertTrue(a.isRecovering(at: 189))
        XCTAssertFalse(a.isRecovering(at: 190))
    }

    func testTwoTripsCountTwiceAndRecoveryRestarts() {
        var a = AwayTracker(recoverySeconds: 60)
        a.set(away: true, at: 10); a.set(away: false, at: 20)
        a.set(away: true, at: 200); a.set(away: false, at: 230)
        XCTAssertEqual(a.awayCount, 2)
        XCTAssertEqual(a.awayEndedAt, 230)
        XCTAssertTrue(a.isRecovering(at: 250))
    }
}

final class FocusEngineTests: XCTestCase {

    /// 静坐 calibrationSeconds 秒，心率恒定
    private func calibrated(hr: Double = 68, seconds: Int = 10) -> FocusEngine {
        var e = FocusEngine(calibrationSeconds: TimeInterval(seconds))
        for t in 1...seconds { _ = e.tick(elapsed: TimeInterval(t), heartRate: hr, motion: 0) }
        return e
    }

    func testCalibrationProducesNoScores() {
        var e = FocusEngine(calibrationSeconds: 10)
        for t in 1...9 {
            let tick = e.tick(elapsed: TimeInterval(t), heartRate: 70, motion: 0)
            XCTAssertNil(tick.sampleScore)
            XCTAssertEqual(e.phase, .calibrating)
        }
    }

    func testCalibrationFinishesOnTimeAndSetsBaseline() {
        var e = FocusEngine(calibrationSeconds: 10)
        for t in 1...9 { _ = e.tick(elapsed: TimeInterval(t), heartRate: 70, motion: 0) }
        let tick = e.tick(elapsed: 10, heartRate: 70, motion: 0)
        XCTAssertTrue(tick.didFinishCalibration)
        XCTAssertNil(tick.sampleScore, "the switch-over second is not scored")
        XCTAssertEqual(e.phase, .running)
        XCTAssertEqual(e.baselineHR, 70)
    }

    func testCalibrationWaitsForHeartRate() {
        var e = FocusEngine(calibrationSeconds: 10)
        for t in 1...15 { _ = e.tick(elapsed: TimeInterval(t), heartRate: nil, motion: 0) }
        XCTAssertEqual(e.phase, .calibrating, "no HR yet → keep calibrating past the deadline")
        _ = e.tick(elapsed: 16, heartRate: 72, motion: 0)
        XCTAssertEqual(e.phase, .running)
        XCTAssertEqual(e.baselineHR, 72)
    }

    func testWalkingHeartRateIsExcludedFromBaseline() {
        var e = FocusEngine(calibrationSeconds: 10)
        e.setAway(true, at: 0)
        for t in 1...5 { _ = e.tick(elapsed: TimeInterval(t), heartRate: 110, motion: 0.3) }
        e.setAway(false, at: 5)
        for t in 6...10 { _ = e.tick(elapsed: TimeInterval(t), heartRate: 66, motion: 0) }
        XCTAssertEqual(e.baselineHR, 66)
    }

    func testStillAndCalmScoresHigh() {
        var e = calibrated()
        var last: Double?
        for t in 11...30 { last = e.tick(elapsed: TimeInterval(t), heartRate: 68, motion: 0.01).sampleScore }
        XCTAssertEqual(last ?? 0, 100, accuracy: 1e-9)
    }

    func testFidgetingDropsScore() {
        var e = calibrated()
        var last: Double?
        for t in 11...60 { last = e.tick(elapsed: TimeInterval(t), heartRate: 86, motion: 0.13).sampleScore }
        // raw = 100 - 50.8 (motion) - 34.7 (HR) ≈ 14.5
        XCTAssertLessThan(last ?? 100, 40)
    }

    func testAwaySecondsAreNotScoredAndAreCounted() {
        var e = calibrated()
        _ = e.tick(elapsed: 11, heartRate: 68, motion: 0)
        let shown = e.score
        e.setAway(true, at: 11)
        for t in 12...26 {
            XCTAssertNil(e.tick(elapsed: TimeInterval(t), heartRate: 100, motion: 0.3).sampleScore)
        }
        XCTAssertEqual(e.away.awaySeconds, 15)
        XCTAssertEqual(e.away.awayCount, 1)
        XCTAssertEqual(e.score, shown, "the ring keeps the last score while away")
    }

    func testNoHeartRatePenaltyDuringRecoveryGrace() {
        var e = FocusEngine(calibrationSeconds: 10, recoverySeconds: 60)
        for t in 1...10 { _ = e.tick(elapsed: TimeInterval(t), heartRate: 68, motion: 0) }
        e.setAway(true, at: 10)
        for t in 11...20 { _ = e.tick(elapsed: TimeInterval(t), heartRate: 100, motion: 0.3) }
        e.setAway(false, at: 20)
        // 刚坐下，心率还是 100：恢复期内不扣心率分
        var recovering: Double?
        for t in 21...30 { recovering = e.tick(elapsed: TimeInterval(t), heartRate: 100, motion: 0).sampleScore }
        XCTAssertGreaterThan(recovering ?? 0, 70)
        // 恢复期过了还是 100 → 开始扣分
        var after: Double?
        for t in 81...140 { after = e.tick(elapsed: TimeInterval(t), heartRate: 100, motion: 0).sampleScore }
        XCTAssertEqual(after ?? 0, 60, accuracy: 0.1)   // 100 - 40
    }

    func testSessionStats() {
        let t0 = Date(timeIntervalSince1970: 0)
        let samples = [
            FocusSample(t: t0, heartRate: 70, motion: 0, score: nil, label: nil),
            FocusSample(t: t0, heartRate: 70, motion: 0, score: 90, label: nil),
            FocusSample(t: t0, heartRate: 70, motion: 0, score: 70, label: nil),
            FocusSample(t: t0, heartRate: 70, motion: 0, score: 40, label: nil),
            FocusSample(t: t0, heartRate: 70, motion: 0, score: nil, label: nil, away: true),
        ]
        XCTAssertEqual(SessionStats.averageScore(samples)!, 200.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(SessionStats.focusedRatio(samples)!, 2.0 / 3, accuracy: 1e-9)
        XCTAssertNil(SessionStats.averageScore([]))
        XCTAssertNil(SessionStats.focusedRatio([]))
    }
}
