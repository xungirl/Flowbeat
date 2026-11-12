import Foundation
import HealthKit
import CoreMotion

/// 一个时间点的记录。存成 JSON，以后拿来画曲线、训练你自己的模型。
struct FocusSample: Codable {
    let t: Date
    let heartRate: Double?
    let motion: Double
    let score: Double?
    /// 你手动打的标签："focused" / "distracted"，平时为 nil
    let label: String?
}

/// 负责：HealthKit 授权 → 开 workout session 拿实时心率 → CoreMotion 拿手腕动作 → 每秒算一次分。
///
/// 为什么要开 workout？watchOS 只有在 workout 进行中才会每隔几秒测一次心率，
/// 并且允许 app 在你放下手腕后继续在后台运行。类型选 mindAndBody，结束时丢弃，不会存进「健康」。
final class FocusSession: NSObject, ObservableObject {
    enum Phase { case idle, calibrating, running, finished }

    @Published var phase: Phase = .idle
    @Published var heartRate: Double?
    @Published var motion: Double = 0
    @Published var score: Double?
    @Published var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    @Published private(set) var samples: [FocusSample] = []

    private let healthStore = HKHealthStore()
    private let motionManager = CMMotionManager()
    private var workoutSession: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private var scorer = FocusScorer()
    private var motionWindow: [Double] = []   // 最近 10 秒的加速度模长
    private let motionHz = 25.0
    private var startDate: Date?
    private var tickTimer: Timer?
    private var pendingLabel: String?

    // MARK: - 授权

    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            await setError("这台设备不支持 HealthKit")
            return false
        }
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate)]
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        do {
            try await healthStore.requestAuthorization(toShare: share, read: read)
            // 弹窗被关掉 / 点了不允许时，上面不会抛错，要自己再查一次
            guard healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                await setError("请允许「健康」权限：设置 → 健康 → 数据访问 → Flowbeat")
                return false
            }
            await MainActor.run { self.errorMessage = nil }
            return true
        } catch {
            await setError("授权失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 开始 / 结束

    func start() async {
        guard await requestAuthorization() else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            builder.delegate = self
            self.workoutSession = session
            self.builder = builder

            let now = Date()
            session.startActivity(with: now)
            try await builder.beginCollection(at: now)

            await MainActor.run {
                self.scorer = FocusScorer()
                self.samples = []
                self.heartRate = nil
                self.score = nil
                self.elapsed = 0
                self.motionWindow = []
                self.startDate = now
                self.phase = .calibrating
                self.startMotion()
                self.startTicking()
            }
        } catch {
            await setError("启动失败：\(error.localizedDescription)")
        }
    }

    func stop() async {
        await MainActor.run {
            tickTimer?.invalidate()
            tickTimer = nil
            motionManager.stopDeviceMotionUpdates()
        }
        workoutSession?.end()
        if let builder {
            try? await builder.endCollection(at: Date())
            builder.discardWorkout()   // 不往「健康」里塞一条假体能训练
        }
        workoutSession = nil
        builder = nil
        saveSamples()
        await MainActor.run { self.phase = .finished }
    }

    func reset() { phase = .idle }

    /// 手动打标签：下一秒的记录会带上它
    func mark(_ label: String) { pendingLabel = label }

    // MARK: - 汇总（结束页用）

    var averageScore: Double? {
        let s = samples.compactMap(\.score)
        return s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
    }

    /// 分数 ≥ 70 的时间占比
    var focusedRatio: Double? {
        let s = samples.compactMap(\.score)
        return s.isEmpty ? nil : Double(s.filter { $0 >= 70 }.count) / Double(s.count)
    }

    // MARK: - 传感器

    private func startMotion() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1 / motionHz
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.userAcceleration else { return }
            let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            self.motionWindow.append(mag)
            let maxCount = Int(self.motionHz * 10)
            if self.motionWindow.count > maxCount {
                self.motionWindow.removeFirst(self.motionWindow.count - maxCount)
            }
        }
    }

    private func startTicking() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// 每秒一次：更新动作值、推进校准、算分、记一条样本
    private func tick() {
        guard let startDate else { return }
        elapsed = Date().timeIntervalSince(startDate)
        motion = motionWindow.isEmpty ? 0 : motionWindow.reduce(0, +) / Double(motionWindow.count)

        if phase == .calibrating {
            if let hr = heartRate { scorer.addCalibrationHR(hr) }
            if elapsed >= scorer.calibrationSeconds, scorer.finishCalibration() {
                phase = .running
            }
        } else if phase == .running {
            score = scorer.score(heartRate: heartRate, motion: motion)
        }

        samples.append(FocusSample(t: Date(), heartRate: heartRate, motion: motion,
                                   score: phase == .running ? score : nil, label: pendingLabel))
        pendingLabel = nil
    }

    // MARK: - 存档

    /// 存到 app 的 Documents/sessions/<时间>.json
    private func saveSamples() {
        guard !samples.isEmpty,
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let dir = docs.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = ISO8601DateFormatter().string(from: samples[0].t)
            .replacingOccurrences(of: ":", with: "-")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(samples) {
            try? data.write(to: dir.appendingPathComponent("\(name).json"))
        }
    }

    @MainActor private func setError(_ msg: String) { errorMessage = msg }
}

// MARK: - HealthKit 回调：拿到新心率

extension FocusSession: HKLiveWorkoutBuilderDelegate {
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType),
              let q = workoutBuilder.statistics(for: hrType)?.mostRecentQuantity()
        else { return }
        let bpm = q.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        DispatchQueue.main.async { self.heartRate = bpm }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
