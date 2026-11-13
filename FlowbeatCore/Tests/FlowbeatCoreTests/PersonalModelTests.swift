import XCTest
@testable import FlowbeatCore

final class PersonalModelTests: XCTestCase {

    /// 简单的确定性伪随机（LCG），测试数据每次都一样
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func uniform(_ r: ClosedRange<Double>) -> Double { r.lowerBound + next() * (r.upperBound - r.lowerBound) }
    }

    /// 合成数据：专注 = 手腕静止多、动作小、心率接近基线；走神相反。两类在特征空间里可分（有一点噪声）
    private func synthetic(focused: Int, distracted: Int, seed: UInt64 = 42, hrv: Bool = false) -> [LabeledFeatures] {
        var rng = LCG(state: seed)
        var out: [LabeledFeatures] = []
        for _ in 0..<focused {
            out.append(LabeledFeatures(features: FocusFeatures(stillRatio: rng.uniform(0.75...1.0), motionMean: rng.uniform(0.0...0.03),
                                                               hrDelta: rng.uniform(-3...4), hrvMs: hrv ? rng.uniform(50...70) : nil),
                                       focused: true))
        }
        for _ in 0..<distracted {
            out.append(LabeledFeatures(features: FocusFeatures(stillRatio: rng.uniform(0.1...0.5), motionMean: rng.uniform(0.06...0.2),
                                                               hrDelta: rng.uniform(8...20), hrvMs: hrv ? rng.uniform(25...45) : nil),
                                       focused: false))
        }
        return out
    }

    func testLearnsSeparablePattern() throws {
        let model = try XCTUnwrap(PersonalModel.train(synthetic(focused: 20, distracted: 20)))
        XCTAssertEqual(model.trainingAccuracy, 1.0)
        // 没见过的新样本（另一个种子）
        let test = synthetic(focused: 30, distracted: 30, seed: 7)
        let correct = test.filter { (model.probability($0.features) >= 0.5) == $0.focused }.count
        XCTAssertGreaterThanOrEqual(Double(correct) / Double(test.count), 0.95)
        // 权重方向符合直觉：静止 ↑ → 专注 ↑；动作 ↑、心率差 ↑ → 专注 ↓
        let w = Dictionary(uniqueKeysWithValues: zip(PersonalModel.featureNames, model.weights))
        XCTAssertGreaterThan(w["stillRatio"]!, 0)
        XCTAssertLessThan(w["motionMean"]!, 0)
        XCTAssertLessThan(w["hrDelta"]!, 0)
        XCTAssertEqual(w["hrv"]!, 0, "no HRV in any example → its weight never moves")
    }

    func testClearCasesGetConfidentProbabilities() throws {
        let model = try XCTUnwrap(PersonalModel.train(synthetic(focused: 15, distracted: 15)))
        XCTAssertGreaterThan(model.probability(FocusFeatures(stillRatio: 0.98, motionMean: 0.005, hrDelta: 0)), 0.9)
        XCTAssertLessThan(model.probability(FocusFeatures(stillRatio: 0.2, motionMean: 0.15, hrDelta: 15)), 0.1)
    }

    func testFallbackWhenLabelsInsufficient() {
        XCTAssertNil(PersonalModel.train([]))
        XCTAssertNil(PersonalModel.train(synthetic(focused: 30, distracted: 7)), "7 < 8 distracted labels")
        XCTAssertNil(PersonalModel.train(synthetic(focused: 7, distracted: 30)))
        XCTAssertNotNil(PersonalModel.train(synthetic(focused: 8, distracted: 8)))
        let missing = PersonalModel.missingLabels(synthetic(focused: 3, distracted: 10))
        XCTAssertEqual(missing.focused, 5)
        XCTAssertEqual(missing.distracted, 0)
    }

    func testDeterministic() throws {
        let data = synthetic(focused: 12, distracted: 10)
        let a = try XCTUnwrap(PersonalModel.train(data))
        let b = try XCTUnwrap(PersonalModel.train(data))
        XCTAssertEqual(a, b, "same labels → bit-identical weights")
        let f = FocusFeatures(stillRatio: 0.6, motionMean: 0.04, hrDelta: 6)
        XCTAssertEqual(a.probability(f), b.probability(f))
    }

    func testBlendAndMissingFeatures() throws {
        let model = try XCTUnwrap(PersonalModel.train(synthetic(focused: 10, distracted: 10)))
        XCTAssertEqual(model.blendedScore(rule: 64, features: nil), 64, "no window yet → rule score unchanged")
        let f = FocusFeatures(stillRatio: 0.95, motionMean: 0.01, hrDelta: nil)   // no heart rate: hrDelta imputed
        let p = model.probability(f)
        XCTAssertEqual(model.blendedScore(rule: 40, features: f), 0.5 * 40 + 0.5 * 100 * p, accuracy: 1e-9)
        XCTAssertGreaterThan(p, 0.5)
    }

    func testUsesHRVWhenPresent() throws {
        let model = try XCTUnwrap(PersonalModel.train(synthetic(focused: 12, distracted: 12, hrv: true)))
        let w = Dictionary(uniqueKeysWithValues: zip(PersonalModel.featureNames, model.weights))
        XCTAssertGreaterThan(w["hrv"]!, 0, "higher HRV goes with focused in this synthetic set")
        XCTAssertEqual(model.explanation.count, 4)
        XCTAssertGreaterThanOrEqual(abs(model.explanation[0].weight), abs(model.explanation[3].weight))
    }

    func testCodableRoundTrip() throws {
        let model = try XCTUnwrap(PersonalModel.train(synthetic(focused: 8, distracted: 8)))
        let back = try JSONDecoder().decode(PersonalModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(back, model)
    }

    // MARK: - Features from samples / archives

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ i: Int, hr: Double?, motion: Double, score: Double?, label: String? = nil, away: Bool = false) -> FocusSample {
        FocusSample(t: t0.addingTimeInterval(TimeInterval(i)), heartRate: hr, motion: motion, score: score, label: label, away: away)
    }

    func testFeaturesFromSamples() throws {
        var s = (0..<40).map { sample($0, hr: 72, motion: 0.01, score: 90) }
        s += (40..<60).map { sample($0, hr: 80, motion: 0.10, score: 50) }
        s += (60..<70).map { sample($0, hr: 100, motion: 0.3, score: nil, away: true) }   // away: ignored
        let f = try XCTUnwrap(FocusFeatures.make(from: s, baseline: 70))
        XCTAssertEqual(f.stillRatio, 40.0 / 60, accuracy: 1e-9)
        let expectedMotion: Double = (40 * 0.01 + 20 * 0.10) / 60
        let expectedHR: Double = (40 * 72 + 20 * 80) / 60.0
        XCTAssertEqual(f.motionMean, expectedMotion, accuracy: 1e-9)
        XCTAssertEqual(f.hrDelta!, expectedHR - 70, accuracy: 1e-9)
        XCTAssertNil(FocusFeatures.make(from: s, baseline: nil)?.hrDelta)
        XCTAssertNil(FocusFeatures.make(from: Array(s.prefix(19)), baseline: 70), "fewer than 20 seated seconds")
    }

    func testExtractFromArchiveUsesCalibrationBaseline() throws {
        // 10 s 校准（心率 68/70/72 → 中位数 70），然后专注 60 s 打「专注」，走神 60 s 打「走神」
        let calibHR: [Double] = [68, 70, 72]
        var s = (0..<10).map { sample($0, hr: calibHR[$0 % 3], motion: 0, score: nil) }
        s += (10..<70).map { sample($0, hr: 71, motion: 0.005, score: 92) }
        s.append(sample(70, hr: 71, motion: 0.005, score: 92, label: "focused"))
        s += (71..<131).map { sample($0, hr: 85, motion: 0.12, score: 30) }
        s.append(sample(131, hr: 85, motion: 0.12, score: 30, label: "distracted"))
        let labels = LabeledFeatures.extract(from: SessionRecord(samples: s, windows: [], judgments: [], review: nil))
        XCTAssertEqual(labels.map(\.focused), [true, false])
        XCTAssertEqual(labels[0].features.hrDelta!, 1, accuracy: 1e-9, "71 − baseline 70")
        XCTAssertEqual(labels[0].features.stillRatio, 1)
        XCTAssertEqual(labels[1].features.hrDelta!, 15, accuracy: 1e-9)
        XCTAssertEqual(labels[1].features.stillRatio, 0)
        // 存档摘要里也带着
        XCTAssertEqual(SessionDigest.make(name: "x", record: SessionRecord(samples: s, windows: [], judgments: [], review: nil)).labels, labels)
    }
}
