import XCTest
@testable import FlowbeatCore

final class WidgetSnapshotTests: XCTestCase {

    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func date(_ s: String, _ tz: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: tz)!
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    /// minutes 分钟、每分钟 60 秒都专注
    private func digest(_ start: Date, minutes: Int) -> SessionDigest {
        SessionDigest(name: "\(start)", start: start, buckets: (0..<minutes).map {
            MinuteBucket(start: start.addingTimeInterval(TimeInterval($0 * 60)), scored: 60, focused: 60)
        })
    }

    func testMergesIntoQuarterHourBuckets() {
        let tz = "Asia/Shanghai"
        let s = WidgetSnapshot.make(from: [digest(date("2027-05-04 09:05", tz), minutes: 40)],
                                    now: date("2027-05-04 12:00", tz), dailyGoalMinutes: 60)
        // 9:05–9:45 → 9:00(10 min) 9:15(15) 9:30(15)
        XCTAssertEqual(s.buckets.map(\.focused), [600, 900, 900])
        XCTAssertEqual(s.summary(at: date("2027-05-04 12:00", tz), calendar: calendar(tz)).todayMinutes, 40)
    }

    func testTodayResetsAtLocalMidnight() {
        let tz = "America/Los_Angeles"
        let cal = calendar(tz)
        let s = WidgetSnapshot.make(from: [digest(date("2027-05-04 20:00", tz), minutes: 45)],
                                    now: date("2027-05-04 21:00", tz), dailyGoalMinutes: 30)
        let dates = WidgetSnapshot.timelineDates(now: date("2027-05-04 21:00", tz), calendar: cal)
        XCTAssertEqual(dates.count, 2)
        XCTAssertEqual(dates[1], date("2027-05-05 00:00", tz))
        XCTAssertEqual(s.summary(at: dates[0], calendar: cal).todayMinutes, 45)
        let after = s.summary(at: dates[1], calendar: cal)
        XCTAssertEqual(after.todayMinutes, 0, "the midnight entry shows a fresh day")
        XCTAssertEqual(after.streak, 1, "yesterday met the goal, today not over yet")
    }

    func testDropsBucketsOlderThanRetention() {
        let tz = "UTC"
        let now = date("2027-05-04 12:00", tz)
        let old = digest(now.addingTimeInterval(-TimeInterval(WidgetSnapshot.retentionDays + 2) * 86_400), minutes: 30)
        let recent = digest(now.addingTimeInterval(-3600), minutes: 30)
        let s = WidgetSnapshot.make(from: [old, recent], now: now, dailyGoalMinutes: 60)
        XCTAssertEqual(s.buckets.reduce(0) { $0 + $1.focused }, 30 * 60)
    }

    func testRoundTripAndEmpty() throws {
        let s = WidgetSnapshot.make(from: [digest(Date(timeIntervalSince1970: 1_800_000_000), minutes: 20)],
                                    now: Date(timeIntervalSince1970: 1_800_003_600), dailyGoalMinutes: 45)
        XCTAssertEqual(WidgetSnapshot.decode(try s.encoded()), s)
        XCTAssertNil(WidgetSnapshot.decode(Data("nope".utf8)))
        let e = WidgetSnapshot.empty().summary(at: Date(), calendar: calendar("UTC"))
        XCTAssertEqual(e.todayMinutes, 0)
        XCTAssertEqual(e.streak, 0)
        XCTAssertEqual(e.dailyGoalMinutes, FocusHistory.defaultDailyGoalMinutes)
    }

    func testQuarterHourBucketsStayWithinOneLocalDayForOddOffsets() {
        // Nepal is UTC+5:45: a session 23:30–00:30 local must still split 30/30
        let tz = "Asia/Kathmandu"
        let s = WidgetSnapshot.make(from: [digest(date("2027-05-04 23:30", tz), minutes: 60)],
                                    now: date("2027-05-05 01:00", tz), dailyGoalMinutes: 60)
        let sum = s.summary(at: date("2027-05-05 01:00", tz), calendar: calendar(tz))
        XCTAssertEqual(sum.todayMinutes, 30)
        XCTAssertEqual(sum.week[5].focusedMinutes, 30)
    }
}
