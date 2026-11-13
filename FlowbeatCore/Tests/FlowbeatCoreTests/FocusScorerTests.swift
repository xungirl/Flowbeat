import XCTest
@testable import FlowbeatCore

final class FocusScorerTests: XCTestCase {

    // MARK: 校准

    func testCalibrationFailsWithoutHeartRate() {
        var s = FocusScorer()
        XCTAssertFalse(s.finishCalibration())
        XCTAssertNil(s.baselineHR)
    }

    func testCalibrationUsesMedianNotMean() {
        var s = FocusScorer()
        // 一个 120 的异常值（比如刚站起来）不应该把基线拉高
        for hr in [66.0, 120, 68, 70, 67] { s.addCalibrationHR(hr) }
        XCTAssertTrue(s.finishCalibration())
        XCTAssertEqual(s.baselineHR, 68)
    }

    func testCalibrationMedianOfEvenCountTakesUpperMiddle() {
        var s = FocusScorer()
        for hr in [60.0, 70, 80, 90] { s.addCalibrationHR(hr) }
        _ = s.finishCalibration()
        XCTAssertEqual(s.baselineHR, 80)   // sorted[count / 2]
    }

    // MARK: 动作扣分

    func testMotionPenaltyBoundaries() {
        XCTAssertEqual(FocusScorer.motionPenalty(0), 0)
        XCTAssertEqual(FocusScorer.motionPenalty(0.02), 0)              // dead zone 内
        XCTAssertEqual(FocusScorer.motionPenalty(0.085), 30, accuracy: 1e-9)  // 一半
        XCTAssertEqual(FocusScorer.motionPenalty(0.15), 60, accuracy: 1e-9)   // 扣满
        XCTAssertEqual(FocusScorer.motionPenalty(2.0), 60)              // 封顶
    }

    func testMotionPenaltyIsMonotonic() {
        var last = -1.0
        for i in 0...40 {
            let p = FocusScorer.motionPenalty(Double(i) * 0.005)
            XCTAssertGreaterThanOrEqual(p, last)
            last = p
        }
    }

    // MARK: 心率扣分

    func testHRPenaltyNeedsBothHeartRateAndBaseline() {
        XCTAssertEqual(FocusScorer.hrPenalty(heartRate: nil, baseline: 68), 0)
        XCTAssertEqual(FocusScorer.hrPenalty(heartRate: 100, baseline: nil), 0)
    }

    func testHRPenaltyBoundaries() {
        XCTAssertEqual(FocusScorer.hrPenalty(heartRate: 60, baseline: 68), 0)   // 低于基线不扣
        XCTAssertEqual(FocusScorer.hrPenalty(heartRate: 73, baseline: 68), 0)   // +5 以内不扣
        XCTAssertEqual(FocusScorer.hrPenalty(heartRate: 80.5, baseline: 68), 20, accuracy: 1e-9)
        XCTAssertEqual(FocusScorer.hrPenalty(heartRate: 88, baseline: 68), 40, accuracy: 1e-9)
        XCTAssertEqual(FocusScorer.hrPenalty(heartRate: 150, baseline: 68), 40)
    }

    func testRawScoreRangeIsZeroToHundred() {
        XCTAssertEqual(FocusScorer.rawScore(heartRate: 68, motion: 0, baseline: 68), 100)
        XCTAssertEqual(FocusScorer.rawScore(heartRate: 200, motion: 5, baseline: 68), 0)
    }

    /// compare_models.py 里新用例的 rule_score_mean 就是按这个公式算的
    func testRawScoreMatchesComparisonScriptCases() {
        XCTAssertEqual(FocusScorer.rawScore(heartRate: 71, motion: 0.045, baseline: 68), 88.5, accuracy: 0.1)  // typing
        XCTAssertEqual(FocusScorer.rawScore(heartRate: nil, motion: 0.025, baseline: 68), 97.7, accuracy: 0.1) // no-hr
    }

    // MARK: 平滑

    func testFirstScoreIsUnsmoothed() {
        var s = FocusScorer()
        XCTAssertEqual(s.score(heartRate: nil, motion: 0.15), 40, accuracy: 1e-9)
    }

    func testExponentialSmoothingMovesTwentyPercentPerTick() {
        var s = FocusScorer()
        _ = s.score(heartRate: nil, motion: 0)          // 100
        let next = s.score(heartRate: nil, motion: 0.15) // raw 40
        XCTAssertEqual(next, 100 + 0.2 * (40 - 100), accuracy: 1e-9)  // 88
    }

    func testSmoothingConvergesToRawScore() {
        var s = FocusScorer()
        _ = s.score(heartRate: nil, motion: 0)
        var v = 0.0
        for _ in 0..<60 { v = s.score(heartRate: nil, motion: 0.15) }
        XCTAssertEqual(v, 40, accuracy: 0.01)
    }

    func testSingleSpikeIsDampened() {
        var s = FocusScorer()
        for _ in 0..<10 { _ = s.score(heartRate: nil, motion: 0) }
        let spike = s.score(heartRate: nil, motion: 1.0)   // 甩一下手
        XCTAssertGreaterThan(spike, 85, "one noisy second should not drop the ring below the focus band")
    }

    // MARK: 滑动平均

    func testRollingMeanKeepsOnlyLastN() {
        var r = RollingMean(capacity: 3)
        XCTAssertEqual(r.mean, 0)
        for x in [1.0, 2, 3, 4, 5] { r.append(x) }
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.mean, 4)
        r.reset()
        XCTAssertEqual(r.count, 0)
    }
}
