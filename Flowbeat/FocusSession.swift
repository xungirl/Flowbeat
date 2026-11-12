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
    /// 这一秒是否离座（走路 / 跑步），离座时不打分
    var away: Bool = false
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

    // 离座检测：系统判断你在走路 / 跑步时暂停打分，不算走神
    @Published var isAway = false
    @Published private(set) var awayCount = 0
    @Published private(set) var awaySeconds: TimeInterval = 0
    @Published private(set) var steps = 0
    /// 刚坐回来时心率还没降下来，这段时间不按心率扣分
    private let recoverySeconds: TimeInterval = 60
    private var awayEndedAt: TimeInterval?

    private let healthStore = HKHealthStore()
    private let motionManager = CMMotionManager()
    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
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
                #if targetEnvironment(simulator)
                self.scorer.calibrationSeconds = 10
                #endif
                self.samples = []
                self.heartRate = nil
                self.score = nil
                self.elapsed = 0
                self.motionWindow = []
                self.isAway = false
                self.awayCount = 0
                self.awaySeconds = 0
                self.steps = 0
                self.awayEndedAt = nil
                self.startDate = now
                self.startActivityTracking(from: now)
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
            activityManager.stopActivityUpdates()
            pedometer.stopUpdates()
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

    /// 系统的活动识别（静止 / 走路 / 跑步）+ 计步。判断有几秒延迟，属正常。
    private func startActivityTracking(from start: Date) {
        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let self, let activity, activity.confidence != .low else { return }
                if activity.walking || activity.running {
                    self.setAway(true)
                } else if activity.stationary {
                    self.setAway(false)
                }
            }
        }
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: start) { [weak self] data, _ in
                guard let n = data?.numberOfSteps.intValue else { return }
                DispatchQueue.main.async { self?.steps = n }
            }
        }
    }

    private func setAway(_ away: Bool) {
        guard away != isAway else { return }
        isAway = away
        if away {
            awayCount += 1
        } else {
            awayEndedAt = elapsed
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
        #if targetEnvironment(simulator)
        simulateSensors()
        #endif

        if phase == .calibrating {
            // 走动时的心率不能当「平静基线」
            if let hr = heartRate, !isAway { scorer.addCalibrationHR(hr) }
            if elapsed >= scorer.calibrationSeconds, scorer.finishCalibration() {
                phase = .running
            }
        } else if phase == .running {
            if isAway {
                awaySeconds += 1   // 离座：不打分，也不计入专注占比
            } else {
                let recovering = awayEndedAt.map { elapsed - $0 < recoverySeconds } ?? false
                score = scorer.score(heartRate: recovering ? nil : heartRate, motion: motion)
            }
        }

        let scored = phase == .running && !isAway
        samples.append(FocusSample(t: Date(), heartRate: heartRate, motion: motion,
                                   score: scored ? score : nil, label: pendingLabel, away: isAway))
        pendingLabel = nil
    }

    var calibrationSeconds: TimeInterval { scorer.calibrationSeconds }

    #if targetEnvironment(simulator)
    /// 模拟器没有真传感器：校准后按 60 秒循环造假数据——专注 35 秒 → 走神 10 秒 → 起身走路 15 秒。
    /// 真机不会编译这段。
    private func simulateSensors() {
        let afterCalibration = elapsed - scorer.calibrationSeconds
        let t = afterCalibration > 0 ? afterCalibration.truncatingRemainder(dividingBy: 60) : 0
        switch t {
        case 45...:   // 走路
            setAway(true)
            heartRate = 95 + Double.random(in: -3...3)
            motion = Double.random(in: 0.18...0.30)
            steps += 2
        case 35...:   // 坐着走神：抖腿、看手机
            setAway(false)
            heartRate = 86 + Double.random(in: -2...2)
            motion = Double.random(in: 0.08...0.18)
        default:      // 专注
            setAway(false)
            heartRate = 70 + Double.random(in: -2...2)
            motion = Double.random(in: 0...0.02)
        }
    }
    #endif

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
