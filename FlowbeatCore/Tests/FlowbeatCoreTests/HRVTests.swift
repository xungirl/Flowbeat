import XCTest
@testable import FlowbeatCore

final class HRVTests: XCTestCase {
    let end = Date(timeIntervalSince1970: 1_794_493_800)

    func testNoSamplesMeansNotAvailable() {
        XCTAssertNil(HRVSummary.latest(from: [], at: end))
    }

    func testPicksMostRecentWithinLookback() {
        let samples = [
            HRVSample(date: end - 3 * 3600, sdnnMs: 55),
            HRVSample(date: end - 40 * 60, sdnnMs: 38.26),
            HRVSample(date: end - 2 * 3600, sdnnMs: 60),
        ]
        let r = HRVSummary.latest(from: samples, at: end)
        XCTAssertEqual(r, HRVReading(sdnnMs: 38.3, ageMinutes: 40))
    }

    func testIgnoresTooOldFutureAndImplausible() {
        let samples = [
            HRVSample(date: end - 7 * 3600, sdnnMs: 50),   // 超过 6 小时
            HRVSample(date: end + 60, sdnnMs: 50),         // 窗口之后
            HRVSample(date: end - 60, sdnnMs: 900),        // 噪声
            HRVSample(date: end - 60, sdnnMs: 1),          // 噪声
        ]
        XCTAssertNil(HRVSummary.latest(from: samples, at: end))
    }

    func testCustomLookback() {
        let s = [HRVSample(date: end - 20 * 60, sdnnMs: 45)]
        XCTAssertNil(HRVSummary.latest(from: s, at: end, lookback: 10 * 60))
        XCTAssertNotNil(HRVSummary.latest(from: s, at: end, lookback: 30 * 60))
    }

    func testWindowSummaryIncludesHRVWhenAvailable() throws {
        let samples = (0..<60).map { FocusSample(t: end.addingTimeInterval(Double($0) - 59), heartRate: 70, motion: 0.01, score: 90, label: nil) }
        let w = WindowSummary.make(from: samples, baseline: 68, sessionStart: end - 600,
                                   hrv: [HRVSample(date: end - 15 * 60, sdnnMs: 41.04)])
        XCTAssertEqual(w.hrvSdnnMs, 41.0)
        XCTAssertEqual(w.hrvAgeMin, 15)
        let obj = try JSONSerialization.jsonObject(with: FlowbeatJSON.encoder.encode(w)) as! [String: Any]
        XCTAssertEqual(obj["hrv_sdnn_ms"] as? Double, 41.0)
        XCTAssertEqual(obj["hrv_age_min"] as? Int, 15)
    }

    func testWindowSummaryOmitsHRVWhenUnavailable() throws {
        let samples = [FocusSample(t: end, heartRate: 70, motion: 0.01, score: 90, label: nil)]
        let w = WindowSummary.make(from: samples, baseline: 68, sessionStart: end - 600)
        XCTAssertNil(w.hrvSdnnMs)
        let obj = try JSONSerialization.jsonObject(with: FlowbeatJSON.encoder.encode(w)) as! [String: Any]
        XCTAssertNil(obj["hrv_sdnn_ms"], "unavailable HRV must not be sent as 0 or null")
        XCTAssertNil(obj["hrv_age_min"])
    }
}
