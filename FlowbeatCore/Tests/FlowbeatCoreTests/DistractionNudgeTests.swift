import XCTest
@testable import FlowbeatCore

final class DistractionNudgeTests: XCTestCase {

    /// 从 from 秒到 to 秒（含）每秒喂一次同样的输入，返回提醒发生在哪几秒
    @discardableResult
    private func run(_ n: inout DistractionNudge, _ range: ClosedRange<Int>, score: Double?,
                     calibrating: Bool = false, away: Bool = false, onBreak: Bool = false) -> [Int] {
        var fired: [Int] = []
        for t in range {
            let input = DistractionNudge.Input(elapsed: TimeInterval(t), score: score, calibrating: calibrating,
                                               away: away, onBreak: onBreak)
            if n.update(input) { fired.append(t) }
        }
        return fired
    }

    func testDefaults() {
        let s = NudgeSettings()
        XCTAssertTrue(s.enabled, "on by default")
        XCTAssertEqual(s.distractedMinutes, 3)
        XCTAssertEqual(s.cooldownMinutes, 10)
    }

    func testSettingsAreClamped() {
        let s = NudgeSettings(distractedMinutes: 0, cooldownMinutes: 999)
        XCTAssertEqual(s.distractedMinutes, NudgeSettings.distractedMinutesRange.lowerBound)
        XCTAssertEqual(s.cooldownMinutes, NudgeSettings.cooldownMinutesRange.upperBound)
    }

    func testFocusedNeverNudges() {
        var n = DistractionNudge()
        XCTAssertEqual(run(&n, 0...3600, score: 85), [])
    }

    func testNudgesAfterThreeDistractedMinutes() {
        var n = DistractionNudge()
        XCTAssertEqual(run(&n, 100...279, score: 20), [], "2:59 of distraction is not enough")
        XCTAssertEqual(run(&n, 280...280, score: 20), [280], "fires exactly at 3:00")
        XCTAssertEqual(n.nudgeCount, 1)
    }

    func testCooldownLimitsToOneNudgePerTenMinutes() {
        var n = DistractionNudge()
        // 30 分钟一直走神：0+180 提醒，之后每 10 分钟一次（180, 780, 1380）
        let fired = run(&n, 0...1800, score: 10)
        XCTAssertEqual(fired, [180, 780, 1380])
    }

    func testCustomMinutesAndCooldown() {
        var n = DistractionNudge(settings: NudgeSettings(distractedMinutes: 1, cooldownMinutes: 5))
        XCTAssertEqual(run(&n, 0...700, score: 10), [60, 360, 660])
    }

    func testStreakMustRestartAfterNudge() {
        var n = DistractionNudge(settings: NudgeSettings(distractedMinutes: 3, cooldownMinutes: 3))
        XCTAssertEqual(run(&n, 0...180, score: 10), [180])
        // 冷却 3 分钟也过了，但提醒后要重新连续走神满 3 分钟
        XCTAssertEqual(run(&n, 181...359, score: 10), [])
        XCTAssertEqual(run(&n, 360...360, score: 10), [360])
    }

    func testBriefRecoveryWithinGraceDoesNotReset() {
        var n = DistractionNudge()
        run(&n, 0...119, score: 20)
        run(&n, 120...129, score: 75)       // 10 s 回神 < 15 s 宽限期
        XCTAssertEqual(n.distractedSince, 0)
        XCTAssertEqual(run(&n, 130...180, score: 20), [180])
    }

    func testSustainedRecoveryResetsStreak() {
        var n = DistractionNudge()
        run(&n, 0...119, score: 20)
        run(&n, 120...135, score: 75)       // 回神 15 s（120 → 135）= 宽限期 → 清零
        XCTAssertNil(n.distractedSince)
        XCTAssertEqual(run(&n, 136...315, score: 20), [], "new streak started at 136, 3 min ends at 316")
        XCTAssertEqual(run(&n, 316...316, score: 20), [316])
    }

    func testNoNudgeDuringCalibration() {
        var n = DistractionNudge()
        XCTAssertEqual(run(&n, 0...600, score: 10, calibrating: true), [])
        XCTAssertNil(n.distractedSince)
    }

    func testAwayResetsAndNeverNudges() {
        var n = DistractionNudge()
        run(&n, 0...170, score: 20)
        XCTAssertEqual(run(&n, 171...400, score: 20, away: true), [], "walking is not distraction")
        XCTAssertNil(n.distractedSince)
        XCTAssertEqual(run(&n, 401...580, score: 20), [], "streak restarts after sitting back down")
        XCTAssertEqual(run(&n, 581...581, score: 20), [581])
    }

    func testNoNudgeDuringBreakOrWithoutScore() {
        var n = DistractionNudge()
        XCTAssertEqual(run(&n, 0...600, score: 10, onBreak: true), [])
        XCTAssertEqual(run(&n, 601...1200, score: nil), [])
    }

    func testDisabledNeverNudges() {
        var n = DistractionNudge(settings: NudgeSettings(enabled: false))
        XCTAssertEqual(run(&n, 0...3600, score: 0), [])
    }

    func testThresholdIsExclusive() {
        var n = DistractionNudge()
        XCTAssertEqual(run(&n, 0...600, score: DistractionNudge.defaultThreshold), [], "score == 40 is not distracted")
    }
}
