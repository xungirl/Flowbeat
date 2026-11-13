import XCTest
@testable import FlowbeatCore

final class FocusHistoryTests: XCTestCase {

    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    /// 某个时区的当地时间 → Date
    private func date(_ s: String, _ tz: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: tz)!
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)!
    }

    /// 从 start 开始，每秒一条样本，score 固定
    private func record(from start: Date, seconds: Int, score: Double?) -> SessionRecord {
        let samples = (0..<seconds).map {
            FocusSample(t: start.addingTimeInterval(TimeInterval($0)), heartRate: 70, motion: 0, score: score, label: nil)
        }
        return SessionRecord(samples: samples, windows: [], judgments: [], review: nil)
    }

    private func digest(_ start: Date, minutes: Int, score: Double? = 90, name: String? = nil) -> SessionDigest {
        SessionDigest.make(name: name ?? "\(start.timeIntervalSince1970)", record: record(from: start, seconds: minutes * 60, score: score))
    }

    // MARK: - SessionDigest

    func testDigestBucketsByMinuteAndSkipsUnscored() {
        let start = Date(timeIntervalSince1970: 1_800_000_030)   // :30 into a minute
        var samples = record(from: start, seconds: 90, score: 80).samples
        samples += record(from: start.addingTimeInterval(90), seconds: 30, score: nil).samples   // away / calibration
        samples += record(from: start.addingTimeInterval(120), seconds: 30, score: 20).samples
        let d = SessionDigest.make(name: "x", record: SessionRecord(samples: samples, windows: [], judgments: [], review: nil))
        XCTAssertEqual(d.buckets.map(\.scored), [30, 60, 30])
        XCTAssertEqual(d.buckets.map(\.focused), [30, 60, 0])
        XCTAssertEqual(d.buckets[0].start.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0)
        XCTAssertEqual(d.start, start)
    }

    // MARK: - Day boundaries and time zones

    func testSessionAcrossMidnightIsSplitBetweenDays() {
        let tz = "America/Los_Angeles"
        let cal = calendar(tz)
        // 23:40 → 00:20, 40 minutes, all focused
        let d = digest(date("2027-03-01 23:40:00", tz), minutes: 40)
        let days = FocusHistory.focusedSecondsByDay([d], calendar: cal)
        XCTAssertEqual(days[cal.startOfDay(for: date("2027-03-01 12:00:00", tz))], 20 * 60)
        XCTAssertEqual(days[cal.startOfDay(for: date("2027-03-02 12:00:00", tz))], 20 * 60)
    }

    func testSameDataDifferentTimeZoneMovesTheDay() {
        // 07:00 UTC on Mar 2 = 23:00 Mar 1 in Los Angeles (PST, UTC-8) = 15:00 Mar 2 in Shanghai
        let d = digest(date("2027-03-02 07:00:00", "UTC"), minutes: 30)
        let la = FocusHistory.summary([d], now: date("2027-03-01 23:50:00", "America/Los_Angeles"),
                                      calendar: calendar("America/Los_Angeles"))
        XCTAssertEqual(la.todayMinutes, 30, "in LA this is still Mar 1, today")
        let sh = FocusHistory.summary([d], now: date("2027-03-02 16:00:00", "Asia/Shanghai"),
                                      calendar: calendar("Asia/Shanghai"))
        XCTAssertEqual(sh.todayMinutes, 30)
        let shNextDay = FocusHistory.summary([d], now: date("2027-03-03 09:00:00", "Asia/Shanghai"),
                                             calendar: calendar("Asia/Shanghai"))
        XCTAssertEqual(shNextDay.todayMinutes, 0)
        XCTAssertEqual(shNextDay.week[5].focusedMinutes, 30, "yesterday in the 7-day view")
    }

    func testHalfHourOffsetTimeZone() {
        // India is UTC+5:30: 18:20 UTC = 23:50 IST, so a 20-minute session is 10 min one day, 10 the next
        let tz = "Asia/Kolkata"
        let d = digest(date("2027-03-01 18:20:00", "UTC"), minutes: 20)
        let days = FocusHistory.focusedSecondsByDay([d], calendar: calendar(tz))
        XCTAssertEqual(days.values.sorted(), [600, 600])
    }

    func testWeekHasSevenDaysEndingTodayIncludingEmptyDays() {
        let tz = "Europe/Berlin"
        let cal = calendar(tz)
        let now = date("2027-06-10 20:00:00", tz)
        let s = FocusHistory.summary([digest(date("2027-06-08 09:00:00", tz), minutes: 45),
                                      digest(date("2027-06-10 09:00:00", tz), minutes: 25),
                                      digest(date("2027-06-01 09:00:00", tz), minutes: 99)],   // > 7 days ago
                                     now: now, calendar: cal)
        XCTAssertEqual(s.week.count, 7)
        XCTAssertEqual(s.week.last?.day, cal.startOfDay(for: now))
        XCTAssertEqual(s.week.first?.day, cal.startOfDay(for: date("2027-06-04 12:00:00", tz)))
        XCTAssertEqual(s.week.map(\.focusedMinutes), [0, 0, 0, 0, 45, 0, 25])
        XCTAssertEqual(s.todayMinutes, 25)
    }

    func testWeekAcrossDaylightSavingChange() {
        // US DST starts 2027-03-14 (that day has 23 hours). The 7 days must still be 7 distinct local midnights.
        let tz = "America/New_York"
        let cal = calendar(tz)
        let now = date("2027-03-16 10:00:00", tz)
        let s = FocusHistory.summary([digest(date("2027-03-14 09:00:00", tz), minutes: 30)], now: now, calendar: cal)
        let hours = cal.dateComponents([.hour], from: s.week[0].day).hour
        XCTAssertEqual(hours, 0)
        XCTAssertEqual(Set(s.week.map(\.day)).count, 7)
        XCTAssertTrue(s.week.allSatisfy { cal.component(.hour, from: $0.day) == 0 })
        XCTAssertEqual(s.week[4].focusedMinutes, 30)
    }

    // MARK: - Streak

    func testStreakCountsConsecutiveDaysMeetingGoal() {
        let tz = "Asia/Shanghai"
        let cal = calendar(tz)
        let digests = [
            digest(date("2027-05-01 10:00:00", tz), minutes: 70),
            digest(date("2027-05-02 10:00:00", tz), minutes: 60),   // exactly the goal
            digest(date("2027-05-03 10:00:00", tz), minutes: 30),   // two sessions add up
            digest(date("2027-05-03 15:00:00", tz), minutes: 30),
            digest(date("2027-05-04 10:00:00", tz), minutes: 61),
        ]
        let s = FocusHistory.summary(digests, now: date("2027-05-04 22:00:00", tz), calendar: cal, dailyGoalMinutes: 60)
        XCTAssertEqual(s.streak, 4)
        XCTAssertTrue(s.todayGoalMet)
    }

    func testStreakNotBrokenByUnfinishedToday() {
        let tz = "Asia/Shanghai"
        let cal = calendar(tz)
        let digests = [digest(date("2027-05-02 10:00:00", tz), minutes: 60),
                       digest(date("2027-05-03 10:00:00", tz), minutes: 60),
                       digest(date("2027-05-04 08:00:00", tz), minutes: 10)]   // today, not yet met
        let s = FocusHistory.summary(digests, now: date("2027-05-04 09:00:00", tz), calendar: cal, dailyGoalMinutes: 60)
        XCTAssertEqual(s.streak, 2)
        XCTAssertFalse(s.todayGoalMet)
        XCTAssertEqual(s.todayProgress, 10.0 / 60, accuracy: 1e-9)
    }

    func testStreakBrokenByMissedDay() {
        let tz = "Asia/Shanghai"
        let cal = calendar(tz)
        let digests = [digest(date("2027-05-01 10:00:00", tz), minutes: 60),
                       digest(date("2027-05-03 10:00:00", tz), minutes: 60)]
        XCTAssertEqual(FocusHistory.summary(digests, now: date("2027-05-03 20:00:00", tz), calendar: cal).streak, 1)
        XCTAssertEqual(FocusHistory.summary(digests, now: date("2027-05-05 20:00:00", tz), calendar: cal).streak, 0,
                       "yesterday missed → streak is 0")
        XCTAssertEqual(FocusHistory.summary([], now: Date(), calendar: cal).streak, 0)
    }

    func testStreakAcrossDaylightSaving() {
        let tz = "America/New_York"
        let cal = calendar(tz)
        let digests = (12...16).map { digest(date("2027-03-\($0) 09:00:00", tz), minutes: 60) }
        XCTAssertEqual(FocusHistory.summary(digests, now: date("2027-03-16 23:00:00", tz), calendar: cal).streak, 5)
    }

    // MARK: - Best hour

    func testBestHourUsesRatioAndMinimumMinutes() {
        let tz = "Asia/Shanghai"
        let cal = calendar(tz)
        let digests = [
            digest(date("2027-05-01 09:00:00", tz), minutes: 40, score: 90),     // 9:00 hour: 40/40 focused
            digest(date("2027-05-01 14:00:00", tz), minutes: 50, score: 50),     // 14:00: 0/50
            digest(date("2027-05-01 20:00:00", tz), minutes: 5, score: 90),      // 20:00: 100% but only 5 min
        ]
        let best = FocusHistory.bestHour(digests, calendar: cal)
        XCTAssertEqual(best?.hour, 9)
        XCTAssertEqual(best?.focusedRatio, 1)
        XCTAssertEqual(best?.scoredMinutes, 40)
        // 同一份数据换到 UTC：9:00 上海 = 1:00 UTC
        XCTAssertEqual(FocusHistory.bestHour(digests, calendar: calendar("UTC"))?.hour, 1)
    }

    func testBestHourNilWithoutEnoughData() {
        let cal = calendar("UTC")
        XCTAssertNil(FocusHistory.bestHour([], calendar: cal))
        XCTAssertNil(FocusHistory.bestHour([digest(Date(timeIntervalSince1970: 1_800_000_000), minutes: 9)], calendar: cal))
    }

    // MARK: - DigestStore

    func testDigestStoreRefreshAddsAndRemoves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DigestStore(file: dir.appendingPathComponent("digests.json"))

        let r1 = record(from: Date(timeIntervalSince1970: 1_800_000_000), seconds: 120, score: 90)
        let r2 = record(from: Date(timeIntervalSince1970: 1_800_100_000), seconds: 60, score: 30)
        try FlowbeatJSON.sessionEncoder.encode(r1).write(to: archive.appendingPathComponent("a.json"))
        try FlowbeatJSON.sessionEncoder.encode(r2).write(to: archive.appendingPathComponent("b.json"))
        try Data("not json".utf8).write(to: archive.appendingPathComponent("broken.json"))

        var list = store.refresh(archiveDirectory: archive)
        XCTAssertEqual(list.map(\.name), ["a", "b"], "sorted by start, broken file skipped")
        XCTAssertEqual(store.load().count, 2, "cache written")

        try FileManager.default.removeItem(at: archive.appendingPathComponent("a.json"))
        list = store.refresh(archiveDirectory: archive)
        XCTAssertEqual(list.map(\.name), ["b"])
        XCTAssertEqual(store.load().map(\.name), ["b"])
    }

    func testDigestStoreReusesCacheWithoutRereading() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DigestStore(file: dir.appendingPathComponent("digests.json"))
        let url = archive.appendingPathComponent("a.json")
        try FlowbeatJSON.sessionEncoder.encode(record(from: Date(timeIntervalSince1970: 1_800_000_000), seconds: 120, score: 90))
            .write(to: url)
        let first = store.refresh(archiveDirectory: archive)
        // 把存档改坏：如果 refresh 又去解析它，就会丢掉这一条
        try Data("garbage".utf8).write(to: url)
        XCTAssertEqual(store.refresh(archiveDirectory: archive), first)
    }
}
