import XCTest
@testable import FlowbeatCore

final class SessionTimelineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_794_493_800)

    /// 0–59 s 校准（无分数）→ 60–119 s 专注 90 → 120–149 s 离座 → 150–179 s 走神 40
    private func record(timeline: [JudgedWindow]? = nil, windows: [WindowSummary] = [], judgments: [Judgment] = []) -> SessionRecord {
        var samples: [FocusSample] = []
        for i in 0..<180 {
            let score: Double? = i < 60 ? nil : (i < 120 ? 90 : (i < 150 ? nil : 40))
            let label: String? = i == 70 ? "focused" : (i == 160 ? "distracted" : nil)
            samples.append(FocusSample(t: t0.addingTimeInterval(Double(i)), heartRate: 70, motion: 0, score: score,
                                       label: label, away: (120..<150).contains(i)))
        }
        return SessionRecord(samples: samples, windows: windows, judgments: judgments, review: nil, timeline: timeline)
    }

    func testSummaryNumbers() {
        let tl = SessionTimeline(record: record())
        XCTAssertEqual(tl.start, t0)
        XCTAssertEqual(tl.durationMinutes, 179.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(tl.averageScore!, (60 * 90 + 30 * 40) / 90.0, accuracy: 1e-9)
        XCTAssertEqual(tl.focusedRatio!, 60.0 / 90, accuracy: 1e-9)
        XCTAssertEqual(tl.awayCount, 1)
    }

    func testScoresAreBucketedAndSplitAtGaps() {
        let tl = SessionTimeline(record: record(), bucketSeconds: 10)
        XCTAssertEqual(tl.scores.count, 6 + 3)                       // 60 s / 10 + 30 s / 10
        XCTAssertEqual(tl.scores.first?.minute ?? 0, 65.0 / 60, accuracy: 1e-9)   // 桶中点
        XCTAssertEqual(Set(tl.scores.prefix(6).map(\.score)), [90])
        XCTAssertEqual(Set(tl.scores.suffix(3).map(\.score)), [40])
        XCTAssertEqual(tl.scores.map(\.segment), [0, 0, 0, 0, 0, 0, 1, 1, 1], "away gap starts a new line segment")
    }

    func testLabelsAndAwaySpansInMinutes() {
        let tl = SessionTimeline(record: record())
        XCTAssertEqual(tl.labels.map(\.label), ["focused", "distracted"])
        XCTAssertEqual(tl.labels[0].minute, 70.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(tl.awaySpans.count, 1)
        XCTAssertEqual(tl.awaySpans[0].start, 2.0, accuracy: 1e-9)
        XCTAssertEqual(tl.awaySpans[0].end, 2.5, accuracy: 1e-9)
    }

    func testAwayUntilTheEndIsClosed() {
        let s = (0..<10).map { FocusSample(t: t0.addingTimeInterval(Double($0)), heartRate: nil, motion: 0.2, score: nil, label: nil, away: $0 >= 5) }
        let tl = SessionTimeline(record: SessionRecord(samples: s, windows: [], judgments: [], review: nil))
        XCTAssertEqual(tl.awaySpans.count, 1)
        XCTAssertEqual(tl.awaySpans[0].end, 9.0 / 60, accuracy: 1e-9)
    }

    func testJudgmentsUseTimelineMinutes() {
        let j = Judgment(state: "focused", score: 88, reason: "r", source: "llm")
        let tl = SessionTimeline(record: record(timeline: [JudgedWindow(minute: 1, judgment: j), JudgedWindow(minute: 2, judgment: j)]))
        XCTAssertEqual(tl.judgments.map(\.minute), [1, 2])
    }

    func testJudgmentsPreferExactEndSeconds() {
        let j = Judgment(state: "focused", score: 88, reason: "r")
        let tl = SessionTimeline(record: record(timeline: [JudgedWindow(minute: 1, judgment: j, endSeconds: 90)]))
        XCTAssertEqual(tl.judgments.map(\.minute), [1.5])
    }

    func testOldRecordsAlignJudgmentsWithWindows() {
        let w = WindowSummary(minuteOfSession: 2, localTime: "10:02", motionMean: 0, motionMax: 0, stillRatio: 1, awaySeconds: 0)
        let j = Judgment(state: "distracted", score: 30, reason: "r")
        let tl = SessionTimeline(record: record(windows: [w], judgments: [j]))
        XCTAssertEqual(tl.judgments.map(\.minute), [2])
        XCTAssertEqual(tl.judgments.first?.judgment.state, "distracted")
    }

    func testEmptyRecord() {
        let tl = SessionTimeline(record: SessionRecord(samples: [], windows: [], judgments: [], review: nil))
        XCTAssertNil(tl.start)
        XCTAssertEqual(tl.durationMinutes, 0)
        XCTAssertTrue(tl.scores.isEmpty)
        XCTAssertNil(tl.averageScore)
    }
}
