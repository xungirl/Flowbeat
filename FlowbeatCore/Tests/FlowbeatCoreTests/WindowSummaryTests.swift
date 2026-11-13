import XCTest
@testable import FlowbeatCore

final class WindowSummaryTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    // 2026-11-12 14:30:00 UTC
    let start = Date(timeIntervalSince1970: 1_794_493_800)

    private func samples(_ specs: [(hr: Double?, motion: Double, score: Double?, away: Bool)], from offset: TimeInterval) -> [FocusSample] {
        specs.enumerated().map { i, s in
            FocusSample(t: start.addingTimeInterval(offset + Double(i)), heartRate: s.hr, motion: s.motion,
                        score: s.score, label: nil, away: s.away)
        }
    }

    func testBasicStatistics() {
        let s = samples([
            (70, 0.01, 90, false),
            (72, 0.02, 80, false),
            (76, 0.10, 70, false),
            (nil, 0.30, nil, true),
        ], from: 360)
        let w = WindowSummary.make(from: s, baseline: 68.04, sessionStart: start, timeZone: utc)
        XCTAssertEqual(w.minuteOfSession, 6)
        XCTAssertEqual(w.localTime, "14:36")
        XCTAssertEqual(w.baselineHr, 68.0)
        XCTAssertEqual(w.hrMean, 72.7)          // (70+72+76)/3 = 72.666…
        XCTAssertEqual(w.hrMin, 70)
        XCTAssertEqual(w.hrMax, 76)
        XCTAssertEqual(w.hrTrend, 6)            // 最后一个有效心率 - 第一个
        XCTAssertEqual(w.motionMean, 0.108)     // 0.43 / 4 = 0.1075 → 0.108
        XCTAssertEqual(w.motionMax, 0.3)
        XCTAssertEqual(w.stillRatio, 0.5)       // 0.01、0.02 < 0.03
        XCTAssertEqual(w.awaySeconds, 1)
        XCTAssertEqual(w.ruleScoreMean, 80)
    }

    func testNoHeartRateGivesNilHRFields() {
        let s = samples([(nil, 0.01, 95, false), (nil, 0.01, 96, false)], from: 0)
        let w = WindowSummary.make(from: s, baseline: nil, sessionStart: start, timeZone: utc)
        XCTAssertNil(w.hrMean); XCTAssertNil(w.hrMin); XCTAssertNil(w.hrMax); XCTAssertNil(w.hrTrend)
        XCTAssertNil(w.baselineHr)
        XCTAssertEqual(w.stillRatio, 1)
    }

    func testEmptyWindowDoesNotCrash() {
        let w = WindowSummary.make(from: [], baseline: 68, sessionStart: start, timeZone: utc)
        XCTAssertEqual(w.motionMean, 0)
        XCTAssertEqual(w.stillRatio, 0)
        XCTAssertNil(w.ruleScoreMean)
    }

    func testAllAwayWindowHasNoRuleScore() {
        let s = samples(Array(repeating: (hr: 100.0, motion: 0.25, score: nil, away: true), count: 120), from: 600)
        let w = WindowSummary.make(from: s, baseline: 68, sessionStart: start, timeZone: utc)
        XCTAssertEqual(w.awaySeconds, 120)
        XCTAssertNil(w.ruleScoreMean)
    }

    // MARK: 序列化

    func testEncodesSnakeCaseAndOmitsNil() throws {
        let w = WindowSummary(minuteOfSession: 2, localTime: "09:00", motionMean: 0.01, motionMax: 0.02,
                              stillRatio: 1, awaySeconds: 0)
        let obj = try JSONSerialization.jsonObject(with: FlowbeatJSON.encoder.encode(w)) as! [String: Any]
        XCTAssertEqual(obj["minute_of_session"] as? Int, 2)
        XCTAssertNil(obj["hr_mean"], "nil fields are omitted, the backend treats them as missing")
    }

    func testJudgmentDecodesWithAndWithoutSource() throws {
        let old = #"{"state":"focused","score":88,"reason":"手腕静止"}"#
        let new = #"{"state":"unclear","score":50,"reason":"AI 暂不可用","source":"fallback"}"#
        XCTAssertNil(try FlowbeatJSON.decoder.decode(Judgment.self, from: Data(old.utf8)).source)
        XCTAssertEqual(try FlowbeatJSON.decoder.decode(Judgment.self, from: Data(new.utf8)).source, "fallback")
    }

    func testSessionRecordRoundTrip() throws {
        let s = samples([(70, 0.01, 90, false), (nil, 0.2, nil, true)], from: 0)
        let w = WindowSummary.make(from: s, baseline: 68, sessionStart: start, timeZone: utc)
        let r = SessionRecord(samples: s, windows: [w], judgments: [Judgment(state: "focused", score: 90, reason: "x")],
                              review: Review(summary: "s", tip: "t"))
        let data = try FlowbeatJSON.sessionEncoder.encode(r)
        XCTAssertEqual(try FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: data), r)
    }

    func testOldSessionFilesWithoutTimelineStillDecode() throws {
        let old = #"{"samples":[],"windows":[],"judgments":[{"state":"focused","score":90,"reason":"x"}]}"#
        let r = try FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: Data(old.utf8))
        XCTAssertNil(r.timeline)
        XCTAssertNil(r.review)
        XCTAssertEqual(r.judgments.count, 1)
    }

    func testLabeledExamplesAreCappedKeepingNewest() {
        let w = WindowSummary(minuteOfSession: 0, localTime: "00:00", motionMean: 0, motionMax: 0, stillRatio: 1, awaySeconds: 0)
        var list: [LabeledExample] = []
        for i in 0..<25 {
            var wi = w; wi.minuteOfSession = i
            list = LabeledExample.appending(LabeledExample(window: wi, label: "focused"), to: list)
        }
        XCTAssertEqual(list.count, 20)
        XCTAssertEqual(list.first?.window.minuteOfSession, 5)
        XCTAssertEqual(list.last?.window.minuteOfSession, 24)
    }

    // MARK: 契约：Swift 编出来的 JSON 字段 == 后端 Pydantic 的字段（backend/tests 读同一个文件）

    private func contract() throws -> [String: [String]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "contract_fields", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
    }

    private func keys<T: Encodable>(_ value: T) throws -> [String] {
        let obj = try JSONSerialization.jsonObject(with: FlowbeatJSON.encoder.encode(value)) as! [String: Any]
        return obj.keys.sorted()
    }

    /// 所有可选字段都填上，才能看到完整的字段集
    static let fullWindow = WindowSummary(minuteOfSession: 1, localTime: "10:00", baselineHr: 68, hrMean: 70, hrMin: 66,
                                          hrMax: 74, hrTrend: 1, motionMean: 0.01, motionMax: 0.04, stillRatio: 0.9,
                                          awaySeconds: 0, ruleScoreMean: 90)

    func testWindowSummaryMatchesBackendSchema() throws {
        XCTAssertEqual(try keys(Self.fullWindow), try contract()["WindowSummary"])
    }

    func testJudgeRequestMatchesBackendSchema() throws {
        let req = JudgeRequest(window: Self.fullWindow, examples: [], recent: [])
        XCTAssertEqual(try keys(req), try contract()["JudgeRequest"])
    }

    func testJudgmentMatchesBackendSchema() throws {
        let j = Judgment(state: "focused", score: 90, reason: "x", source: "llm")
        XCTAssertEqual(try keys(j), try contract()["Judgment"])
    }

    func testReviewRequestMatchesBackendSchema() throws {
        let req = ReviewRequest(durationMinutes: 1, averageScore: 80, focusedRatio: 0.5, awayCount: 0, awayMinutes: 0,
                                windows: [], judgments: [])
        XCTAssertEqual(try keys(req), try contract()["ReviewRequest"])
    }
}
