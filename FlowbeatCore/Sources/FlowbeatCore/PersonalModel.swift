import Foundation

// 用你自己的「专注 / 走神」标签，在手表上训练一个小模型（逻辑回归），和规则分混合。
//
// 为什么是逻辑回归：
// - 可解释：每个特征一个权重，正 = 让「专注」更可能，负 = 更不可能，设置页能直接列出来；
// - 数据很少也能训：一个人一周可能只打几十个标签，深一点的模型只会背答案；
// - 便宜、确定：全量梯度下降、权重从 0 开始、固定迭代次数，同样的标签永远训出同样的权重，单元测试能比对；
// - 纯 Swift，不依赖 Create ML / Core ML，FlowbeatCore 在 macOS 上就能测。
//
// 诚实的限制：没有在真实用户的数据上验证过；标签是主观感受，不是「真实专注」的测量。

/// 一个窗口（标签前 60 秒）的特征。全部来自手表本地的样本，不出手表。
public struct FocusFeatures: Codable, Equatable, Sendable {
    /// 手腕静止（< 0.03 g）的秒数占比
    public var stillRatio: Double
    /// 平均手腕加速度（g）
    public var motionMean: Double
    /// 平均心率 − 本次的平静基线（bpm）；没有心率或没有基线时为 nil
    public var hrDelta: Double?
    /// 最近一次 HRV（SDNN，毫秒）；没有读数时为 nil（上架版不读 HRV，所以总是 nil）
    public var hrvMs: Double?

    public init(stillRatio: Double, motionMean: Double, hrDelta: Double? = nil, hrvMs: Double? = nil) {
        self.stillRatio = stillRatio
        self.motionMean = motionMean
        self.hrDelta = hrDelta
        self.hrvMs = hrvMs
    }

    public static let windowSeconds = 60
    /// 窗口里至少要有这么多「坐着、不在休息」的秒，否则不算（刚开始 / 刚坐回来）
    public static let minSamples = 20

    /// 从一段样本算特征。离座、休息的秒不算。
    public static func make<S: Sequence>(from samples: S, baseline: Double?, hrvMs: Double? = nil) -> FocusFeatures?
    where S.Element == FocusSample {
        let seated = samples.filter { !$0.away && $0.onBreak != true }
        guard seated.count >= minSamples else { return nil }
        let motions = seated.map(\.motion)
        let hrs = seated.compactMap(\.heartRate)
        let still = Double(motions.filter { $0 < WindowSummary.stillThreshold }.count) / Double(motions.count)
        let hrDelta: Double? = (baseline != nil && !hrs.isEmpty) ? hrs.reduce(0, +) / Double(hrs.count) - baseline! : nil
        return FocusFeatures(stillRatio: still, motionMean: motions.reduce(0, +) / Double(motions.count),
                             hrDelta: hrDelta, hrvMs: hrvMs)
    }
}

/// 一个训练样本：特征 + 你打的标签
public struct LabeledFeatures: Codable, Equatable, Sendable {
    public var features: FocusFeatures
    /// true = 你标了「专注」，false = 「走神」
    public var focused: Bool

    public init(features: FocusFeatures, focused: Bool) {
        self.features = features
        self.focused = focused
    }

    /// 从一次存档里取出所有标签的训练样本。
    /// 基线 = 第一个有分数的样本之前（校准期）心率的中位数，和 FocusScorer 的算法一样。
    public static func extract(from record: SessionRecord, window: Int = FocusFeatures.windowSeconds) -> [LabeledFeatures] {
        let samples = record.samples
        guard samples.contains(where: { $0.label != nil }) else { return [] }
        let firstScored = samples.firstIndex { $0.score != nil } ?? samples.count
        let calib = samples[..<firstScored].filter { !$0.away }.compactMap(\.heartRate).sorted()
        let baseline = calib.isEmpty ? nil : calib[calib.count / 2]
        var out: [LabeledFeatures] = []
        for (i, s) in samples.enumerated() {
            guard let label = s.label, label == "focused" || label == "distracted" else { continue }
            // 标签记在点按之后的那一秒，特征用它之前的 window 秒
            guard let f = FocusFeatures.make(from: samples[max(0, i - window)..<i], baseline: baseline) else { continue }
            out.append(LabeledFeatures(features: f, focused: label == "focused"))
        }
        return out
    }
}

/// 逻辑回归：p(专注) = σ(b + Σ wᵢ·zᵢ)，zᵢ 是标准化后的特征。
public struct PersonalModel: Codable, Equatable, Sendable {
    /// 每一类至少要有这么多标签才启用（太少的话模型只是在记住那几次）
    public static let minLabelsPerClass = 8
    /// 混合权重：最终分 = (1 − w)·规则分 + w·100·p
    public static let blendWeight = 0.5

    public static let featureNames = ["stillRatio", "motionMean", "hrDelta", "hrv"]

    public struct Hyperparameters: Codable, Equatable, Sendable {
        public var learningRate = 0.5
        public var iterations = 400
        /// L2 正则：数据少时防止权重无限变大（可分的数据上不加正则，权重会一直涨）
        public var l2 = 0.01
        public init() {}
    }

    /// 标准化用的均值和标准差（训练集上算的），顺序同 featureNames
    public let means: [Double]
    public let stds: [Double]
    public let weights: [Double]
    public let bias: Double
    public let focusedCount: Int
    public let distractedCount: Int
    /// 训练集上的准确率（不是泛化能力，只是「有没有学到东西」的健全性检查）
    public let trainingAccuracy: Double

    /// 标签够不够：返回还差多少（都是 0 才能训练）
    public static func missingLabels(_ examples: [LabeledFeatures], minPerClass: Int = minLabelsPerClass) -> (focused: Int, distracted: Int) {
        let f = examples.filter(\.focused).count
        return (max(0, minPerClass - f), max(0, minPerClass - (examples.count - f)))
    }

    /// 标签不够时返回 nil（app 就只用规则分）
    public static func train(_ examples: [LabeledFeatures], minPerClass: Int = minLabelsPerClass,
                             hyper: Hyperparameters = Hyperparameters()) -> PersonalModel? {
        let missing = missingLabels(examples, minPerClass: minPerClass)
        guard missing.focused == 0, missing.distracted == 0 else { return nil }

        let raw = examples.map { rawVector($0.features) }
        let d = featureNames.count
        var means = [Double](repeating: 0, count: d), stds = [Double](repeating: 1, count: d)
        for j in 0..<d {
            let present = raw.compactMap { $0[j] }
            guard !present.isEmpty else { continue }   // 这一列全缺（比如上架版没有 HRV）：z 永远是 0，权重学不动
            let m = present.reduce(0, +) / Double(present.count)
            let v = present.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(present.count)
            means[j] = m
            stds[j] = v > 1e-12 ? v.squareRoot() : 1
        }
        let X = raw.map { standardize($0, means: means, stds: stds) }
        let y = examples.map { $0.focused ? 1.0 : 0.0 }
        let n = Double(X.count)

        // 全量梯度下降，从 0 开始：没有随机数，结果完全确定
        var w = [Double](repeating: 0, count: d), b = 0.0
        for _ in 0..<hyper.iterations {
            var gw = [Double](repeating: 0, count: d), gb = 0.0
            for (x, t) in zip(X, y) {
                let err = sigmoid(b + dot(w, x)) - t
                for j in 0..<d { gw[j] += err * x[j] }
                gb += err
            }
            for j in 0..<d { w[j] -= hyper.learningRate * (gw[j] / n + hyper.l2 * w[j]) }
            b -= hyper.learningRate * gb / n
        }
        let correct = zip(X, y).filter { (sigmoid(b + dot(w, $0)) >= 0.5) == ($1 == 1) }.count
        let f = examples.filter(\.focused).count
        return PersonalModel(means: means, stds: stds, weights: w, bias: b, focusedCount: f,
                             distractedCount: examples.count - f, trainingAccuracy: Double(correct) / n)
    }

    /// p(专注)，0…1
    public func probability(_ f: FocusFeatures) -> Double {
        Self.sigmoid(bias + Self.dot(weights, Self.standardize(Self.rawVector(f), means: means, stds: stds)))
    }

    /// 规则分（0…100）和模型概率混合
    public func blendedScore(rule: Double, features: FocusFeatures?) -> Double {
        guard let features else { return rule }
        return (1 - Self.blendWeight) * rule + Self.blendWeight * 100 * probability(features)
    }

    /// 可解释性：每个特征的权重（标准化之后，所以能互相比较大小），按影响力从大到小
    public var explanation: [(name: String, weight: Double)] {
        zip(Self.featureNames, weights).map { ($0, $1) }.sorted { abs($0.weight) > abs($1.weight) }
    }

    // MARK: - 数学

    static func rawVector(_ f: FocusFeatures) -> [Double?] {
        [f.stillRatio, f.motionMean, f.hrDelta, f.hrvMs]
    }

    /// 缺失值填均值（标准化后 = 0），不影响预测
    static func standardize(_ v: [Double?], means: [Double], stds: [Double]) -> [Double] {
        v.enumerated().map { j, x in x.map { ($0 - means[j]) / stds[j] } ?? 0 }
    }

    static func sigmoid(_ z: Double) -> Double { 1 / (1 + exp(-z)) }
    static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
}
