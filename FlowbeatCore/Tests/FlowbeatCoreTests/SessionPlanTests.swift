import XCTest
@testable import FlowbeatCore

/// 假时钟：测试里手动拨时间，不等真的 25 分钟
private final class FakeClock {
    private(set) var now: Date
    init(_ start: Date) { now = start }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

final class PomodoroTimerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testDefaultsAre25And5() {
        let s = PomodoroSettings()
        XCTAssertEqual(s.workMinutes, 25)
        XCTAssertEqual(s.breakMinutes, 5)
    }

    func testSettingsClamped() {
        let s = PomodoroSettings(workMinutes: 1, breakMinutes: 100)
        XCTAssertEqual(s.workMinutes, 5, "work must outlast the 60 s calibration")
        XCTAssertEqual(s.breakMinutes, 30)
    }

    func testPhaseBoundaries() {
        let s = PomodoroSettings()
        func p(_ t: TimeInterval) -> PomodoroTimer.Phase { PomodoroTimer.phase(atElapsed: t, settings: s) }
        XCTAssertEqual(p(0).kind, .work)
        XCTAssertEqual(p(0).cycle, 1)
        XCTAssertEqual(p(1499).kind, .work)
        XCTAssertEqual(p(1500).kind, .rest, "break starts exactly at 25:00")
        XCTAssertEqual(p(1500).cycle, 1)
        XCTAssertEqual(p(1799).kind, .rest)
        XCTAssertEqual(p(1800).kind, .work, "second work block at 30:00")
        XCTAssertEqual(p(1800).cycle, 2)
        XCTAssertEqual(p(1800).endsAt, 3300)
        XCTAssertEqual(p(1500).remaining(at: 1620), 180)
        XCTAssertEqual(p(-5).kind, .work, "clock skew before start is still the first work block")
    }

    func testTransitionsWithFakeClock() {
        let clock = FakeClock(t0)
        var timer = PomodoroTimer(start: t0)
        var events: [PomodoroTimer.Event] = []
        // 每秒推进一次，走 61 分钟
        for _ in 0..<(61 * 60) {
            clock.advance(1)
            if let e = timer.update(now: clock.now) { events.append(e) }
        }
        XCTAssertEqual(events, [
            .breakStarted(cycle: 1),   // 25:00
            .workStarted(cycle: 2),    // 30:00
            .breakStarted(cycle: 2),   // 55:00
            .workStarted(cycle: 3),    // 60:00
        ])
        XCTAssertEqual(timer.current.kind, .work)
        XCTAssertEqual(timer.current.cycle, 3)
    }

    func testEachTransitionFiresOnce() {
        let clock = FakeClock(t0)
        var timer = PomodoroTimer(start: t0)
        clock.advance(1500)
        XCTAssertEqual(timer.update(now: clock.now), .breakStarted(cycle: 1))
        XCTAssertNil(timer.update(now: clock.now), "same instant: no second haptic")
        clock.advance(1)
        XCTAssertNil(timer.update(now: clock.now))
    }

    func testLongSleepReportsOnlyTheLatestTransition() {
        let clock = FakeClock(t0)
        var timer = PomodoroTimer(start: t0)
        clock.advance(10)
        XCTAssertNil(timer.update(now: clock.now))
        clock.advance(56 * 60)            // wrist down, timer delayed: jumps from work 1 into break 2
        XCTAssertEqual(timer.update(now: clock.now), .breakStarted(cycle: 2))
    }

    func testCustomLengths() {
        let clock = FakeClock(t0)
        var timer = PomodoroTimer(start: t0, settings: PomodoroSettings(workMinutes: 50, breakMinutes: 10))
        clock.advance(49 * 60 + 59)
        XCTAssertNil(timer.update(now: clock.now))
        clock.advance(1)
        XCTAssertEqual(timer.update(now: clock.now), .breakStarted(cycle: 1))
        clock.advance(10 * 60)
        XCTAssertEqual(timer.update(now: clock.now), .workStarted(cycle: 2))
    }
}

final class SessionGoalTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func samples(_ scores: [Double?]) -> [FocusSample] {
        scores.enumerated().map { i, s in
            FocusSample(t: t0.addingTimeInterval(TimeInterval(i)), heartRate: 70, motion: 0, score: s, label: nil)
        }
    }

    func testPlanTreatsZeroGoalAsNone() {
        XCTAssertNil(SessionPlan(goalMinutes: 0).goalMinutes)
        XCTAssertEqual(SessionPlan(goalMinutes: 25).goalMinutes, 25)
    }

    func testFocusedMinutesAndStreak() {
        // 10 s 校准（nil）+ 200 s 专注 + 30 s 走神 + 400 s 专注 + 20 s 离座 + 100 s 专注
        var scores: [Double?] = Array(repeating: nil, count: 10)
        scores += Array(repeating: 85, count: 200)
        scores += Array(repeating: 30, count: 30)
        scores += Array(repeating: 75, count: 400)
        scores += Array(repeating: nil, count: 20)
        scores += Array(repeating: 90, count: 100)
        let s = samples(scores)
        XCTAssertEqual(SessionStats.focusedSeconds(s), 700)
        XCTAssertEqual(SessionStats.focusedMinutes(s), 11)
        XCTAssertEqual(SessionStats.longestFocusStreak(s), 400)
    }

    func testThresholdIsInclusiveAt70() {
        let s = samples([70, 69.9, 70])
        XCTAssertEqual(SessionStats.focusedSeconds(s), 2)
        XCTAssertEqual(SessionStats.longestFocusStreak(s), 1)
    }

    func testEmptySession() {
        XCTAssertEqual(SessionStats.longestFocusStreak([]), 0)
        XCTAssertEqual(SessionStats.focusedMinutes([]), 0)
    }

    func testGoalResult() {
        let s = samples(Array(repeating: 80, count: 25 * 60))
        let met = SessionStats.goalResult(s, goalMinutes: 25)
        XCTAssertEqual(met?.met, true)
        XCTAssertEqual(met?.progress, 1)
        let missed = SessionStats.goalResult(Array(s.prefix(12 * 60 + 59)), goalMinutes: 25)
        XCTAssertEqual(missed?.focusedMinutes, 12)
        XCTAssertEqual(missed?.met, false)
        XCTAssertEqual(missed!.progress, 0.48, accuracy: 1e-9)
        XCTAssertNil(SessionStats.goalResult(s, goalMinutes: nil))
        XCTAssertNil(SessionStats.goalResult(s, goalMinutes: 0))
    }

    func testBreakSamplesRoundTripAndOldArchivesDecode() throws {
        let rec = SessionRecord(samples: [FocusSample(t: t0, heartRate: nil, motion: 0, score: nil, label: nil, onBreak: true)],
                                windows: [], judgments: [], review: nil,
                                plan: SessionPlan(mode: .pomodoro, goalMinutes: 25))
        let data = try FlowbeatJSON.sessionEncoder.encode(rec)
        let back = try FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: data)
        XCTAssertEqual(back, rec)
        // v1 存档：没有 plan，样本没有 on_break
        let v1 = #"{"samples":[{"t":"2027-01-15T08:00:00Z","motion":0,"away":false}],"windows":[],"judgments":[]}"#
        let old = try FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: Data(v1.utf8))
        XCTAssertNil(old.plan)
        XCTAssertNil(old.samples[0].onBreak)
    }
}
