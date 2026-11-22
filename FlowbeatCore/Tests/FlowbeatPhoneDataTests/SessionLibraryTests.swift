import XCTest
import SwiftData
import FlowbeatCore
@testable import FlowbeatPhoneData

@MainActor
final class SessionLibraryTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        container = try FlowbeatStore.makeContainer(.inMemory)
    }

    /// 一次专注：前 60 秒校准（没分数），然后 `focused` 秒 90 分 + `distracted` 秒 40 分，可选离座和标签
    private func sessionData(start: Date, focused: Int, distracted: Int, away: Int = 0,
                             labels: [String] = [], plan: SessionPlan? = nil) throws -> Data {
        var samples: [FocusSample] = []
        var t = start
        func add(_ score: Double?, away: Bool = false, label: String? = nil) {
            samples.append(FocusSample(t: t, heartRate: 70, motion: 0.01, score: score, label: label, away: away))
            t = t.addingTimeInterval(1)
        }
        for _ in 0..<60 { add(nil) }
        for i in 0..<focused { add(90, label: i < labels.count ? labels[i] : nil) }
        for _ in 0..<away { add(nil, away: true) }
        for _ in 0..<distracted { add(40) }
        return try FlowbeatJSON.sessionEncoder.encode(
            SessionRecord(samples: samples, windows: [], judgments: [], review: nil, plan: plan))
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC

    func testUpsertComputesSummaryFields() throws {
        let data = try sessionData(start: t0, focused: 600, distracted: 300, away: 120,
                                   labels: ["focused", "distracted", "focused"],
                                   plan: SessionPlan(mode: .pomodoro, goalMinutes: 15))
        XCTAssertEqual(try SessionLibrary.upsert(name: "2027-01-15T08-00-00Z.json", data: data, into: context), .inserted)

        let s = try XCTUnwrap(SessionLibrary.all(in: context).first)
        XCTAssertEqual(s.name, "2027-01-15T08-00-00Z")
        XCTAssertEqual(s.start, t0)
        XCTAssertEqual(s.durationSeconds, 60 + 600 + 120 + 300 - 1)
        XCTAssertEqual(s.scoredSeconds, 900)
        XCTAssertEqual(s.focusedSeconds, 600)
        XCTAssertEqual(s.longestStreakSeconds, 600)
        XCTAssertEqual(s.awaySeconds, 120)
        XCTAssertEqual(try XCTUnwrap(s.averageScore), (600 * 90 + 300 * 40) / 900.0, accuracy: 1e-9)
        XCTAssertEqual(s.focusedLabels, 2)
        XCTAssertEqual(s.distractedLabels, 1)
        XCTAssertEqual(s.sessionMode, .pomodoro)
        XCTAssertEqual(s.goalMinutes, 15)
        XCTAssertEqual(s.goalMet, false)   // 10 分钟 < 15
        // 完整存档原样保存，可以解回来
        XCTAssertEqual(s.recordData, data)
        XCTAssertEqual(s.record()?.samples.count, 1080)
        // 分钟桶和直接从存档算的一致
        XCTAssertEqual(s.buckets, SessionDigest.make(name: s.name, record: try XCTUnwrap(s.record())).buckets)
    }

    func testReimportUpdatesAndKeepsNote() throws {
        let name = "2027-01-15T08-00-00Z"
        try SessionLibrary.upsert(name: name, data: try sessionData(start: t0, focused: 60, distracted: 0), into: context)
        try XCTUnwrap(SessionLibrary.all(in: context).first).note = "写论文第三章"
        try context.save()

        let result = try SessionLibrary.upsert(name: name + ".json",
                                               data: try sessionData(start: t0, focused: 300, distracted: 0), into: context)
        XCTAssertEqual(result, .updated)
        let all = try SessionLibrary.all(in: context)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].focusedSeconds, 300)
        XCTAssertEqual(all[0].note, "写论文第三章")
    }

    func testCorruptDataIsRejectedAndNotStored() throws {
        XCTAssertThrowsError(try SessionLibrary.upsert(name: "bad", data: Data("{oops".utf8), into: context))
        XCTAssertEqual(try SessionLibrary.all(in: context).count, 0)
    }

    func testNameNormalizationStripsDirectoriesAndExtension() {
        XCTAssertEqual(SessionLibrary.normalizedName("../../etc/x.json"), "x")
        XCTAssertEqual(SessionLibrary.normalizedName("2027-01-15T08-00-00Z"), "2027-01-15T08-00-00Z")
    }

    /// iCloud 合并后同名出现两条：留最近导入的，备注不丢
    func testRemoveDuplicatesKeepsNewestAndMergesNote() throws {
        let data = try sessionData(start: t0, focused: 60, distracted: 0)
        let older = StoredSession(name: "dup")
        older.apply(record: try FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: data), data: data,
                    importedAt: t0)
        older.note = "从另一台设备来的备注"
        let newer = StoredSession(name: "dup")
        newer.apply(record: try FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: data), data: data,
                    importedAt: t0.addingTimeInterval(60))
        context.insert(older)
        context.insert(newer)
        try context.save()

        XCTAssertEqual(try SessionLibrary.removeDuplicates(in: context), 1)
        let all = try SessionLibrary.all(in: context)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].importedAt, t0.addingTimeInterval(60))
        XCTAssertEqual(all[0].note, "从另一台设备来的备注")
        XCTAssertEqual(try SessionLibrary.removeDuplicates(in: context), 0)
    }

    func testLegacyArchiveImportMovesGoodFilesAndLeavesBadOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try sessionData(start: t0, focused: 60, distracted: 0).write(to: dir.appendingPathComponent("a.json"))
        try sessionData(start: t0.addingTimeInterval(7200), focused: 60, distracted: 0)
            .write(to: dir.appendingPathComponent("b.json"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))

        XCTAssertEqual(SessionLibrary.importLegacyArchive(directory: dir, into: context), 2)
        XCTAssertEqual(try SessionLibrary.all(in: context).map(\.name), ["b", "a"])
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left, ["broken.json"])
        // 再跑一次什么都不做
        XCTAssertEqual(SessionLibrary.importLegacyArchive(directory: dir, into: context), 0)
    }

    func testOverviewMonthAndTotals() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // 今天 20 分钟专注，3 天前 40 分钟，40 天前 10 分钟（不在 30 天里，但算进累计）
        try SessionLibrary.upsert(name: "today", data: try sessionData(start: t0, focused: 1200, distracted: 60,
                                                                       labels: ["focused"]), into: context)
        try SessionLibrary.upsert(name: "d3", data: try sessionData(start: t0.addingTimeInterval(-3 * 86400),
                                                                    focused: 2400, distracted: 0), into: context)
        try SessionLibrary.upsert(name: "d40", data: try sessionData(start: t0.addingTimeInterval(-40 * 86400),
                                                                     focused: 600, distracted: 0,
                                                                     labels: ["distracted"]), into: context)
        let o = PhoneOverview.make(try SessionLibrary.all(in: context), now: t0.addingTimeInterval(3600),
                                   calendar: cal, dailyGoalMinutes: 30)
        XCTAssertEqual(o.month.count, 30)
        XCTAssertEqual(o.month.last?.focusedMinutes, 20)
        XCTAssertEqual(o.month[26].focusedMinutes, 40)
        XCTAssertEqual(o.month.map(\.focusedMinutes).reduce(0, +), 60)
        XCTAssertEqual(o.activeDayAverageMinutes, 30)
        XCTAssertEqual(o.totalSessions, 3)
        XCTAssertEqual(o.totalFocusedMinutes, 70)
        XCTAssertEqual(o.history.todayMinutes, 20)
        XCTAssertEqual(o.history.streak, 0)   // 今天没达标，昨天也没有
        XCTAssertEqual(o.focusedLabels, 1)
        XCTAssertEqual(o.distractedLabels, 1)
    }

    func testCSVExportEscapesAndBlocksFormulas() throws {
        try SessionLibrary.upsert(name: "a", data: try sessionData(start: t0, focused: 120, distracted: 60,
                                                                   plan: SessionPlan(goalMinutes: 15)), into: context)
        let s = try XCTUnwrap(SessionLibrary.all(in: context).first)
        s.note = "=HYPERLINK(\"x\"), ch.3"
        let csv = SessionCSV.make([s])
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], SessionCSV.header)
        XCTAssertTrue(lines[1].hasPrefix("2027-01-15T08:00:00Z,"))
        XCTAssertTrue(lines[1].contains(",2,"))          // 专注 2 分钟
        XCTAssertTrue(lines[1].contains(",15,no,"))      // 目标 15 分钟没达成
        XCTAssertTrue(lines[1].hasSuffix(",\"'=HYPERLINK(\"\"x\"\"), ch.3\""))
        XCTAssertEqual(SessionCSV.escape("plain"), "plain")
        XCTAssertEqual(SessionCSV.escape("-5"), "'-5")
        XCTAssertEqual(SessionCSV.escape("two\nlines"), "\"two\nlines\"")
    }

    func testAppContainerFallsBackWhenNoCloudKit() {
        XCTAssertEqual(FlowbeatStore.makeAppContainer(cloudKitContainer: nil).location, .local)
        XCTAssertEqual(FlowbeatStore.makeAppContainer(cloudKitContainer: "").location, .local)
    }
}
