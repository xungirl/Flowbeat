import Foundation
import HealthKit
import CoreMotion
import FlowbeatCore

// FocusSample / SessionRecord / 打分和离座状态机都在 FlowbeatCore（纯逻辑，有单元测试）。
// 这个文件只管传感器、计时器、网络和 UI 状态。

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

    // 离座检测：系统判断你在走路 / 跑步时暂停打分，不算走神。状态机在 engine.away 里，这里是给 UI 的镜像
    @Published private(set) var isAway = false
    @Published private(set) var awayCount = 0
    @Published private(set) var awaySeconds: TimeInterval = 0
    @Published private(set) var steps = 0

    private let healthStore = HKHealthStore()
    private let motionManager = CMMotionManager()
    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private var workoutSession: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private var engine = FocusEngine()
    private let motionHz = 25.0
    private lazy var motionWindow = RollingMean(capacity: Int(motionHz * 10))   // 最近 10 秒的加速度模长
    private var startDate: Date?
    private var tickTimer: Timer?
    private var pendingLabel: String?

    // AI 判断（后端 + 大模型）。连不上后端时这些保持 nil，本地规则照常工作。
    @Published private(set) var aiJudgment: Judgment?
    @Published private(set) var aiReview: Review?
    @Published private(set) var aiReviewLoading = false
    @Published private(set) var aiError: String?
    private(set) var windows: [WindowSummary] = []
    private(set) var judgments: [Judgment] = []
    private(set) var timeline: [JudgedWindow] = []
    private var lastJudgeAt: TimeInterval = 0
    /// 所有判断请求都走这个队列：在线时等于直接发；连不上后端时排队，按 15 s → 30 s → … ≤ 5 min 退避重试，最多 30 条
    private var sync = JudgeSync { try await AIClient.judge($0) }
    /// 还在排队等发送的窗口数（> 0 时 UI 显示「离线」）
    @Published private(set) var pendingJudgments = 0

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
                #if targetEnvironment(simulator)
                self.engine = FocusEngine(calibrationSeconds: 10)
                #else
                self.engine = FocusEngine(calibrationSeconds: 60)
                #endif
                self.samples = []
                self.heartRate = nil
                self.score = nil
                self.elapsed = 0
                self.motionWindow.reset()
                self.syncAway()
                self.steps = 0
                self.aiJudgment = nil
                self.aiReview = nil
                self.aiError = nil
                self.windows = []
                self.judgments = []
                self.timeline = []
                self.sync = JudgeSync { try await AIClient.judge($0) }   // 每次专注一个新队列
                self.pendingJudgments = 0
                self.lastJudgeAt = 0
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
        await MainActor.run {
            self.phase = .finished
            self.aiReviewLoading = true
        }
        // 结束前把排队的窗口最后试一次（不等退避），这样复盘能用上尽量多的判断
        let final = await sync.flush(ignoringBackoff: true)
        await MainActor.run { self.apply(final) }
        await requestReview()
        saveSamples()
    }

    func reset() { phase = .idle }

    /// 手动打标签：下一秒的记录会带上它；同时把最近 1 分钟存成你的 few-shot 例子
    func mark(_ label: String) {
        pendingLabel = label
        guard let startDate, !samples.isEmpty else { return }
        let window = WindowSummary.make(from: Array(samples.suffix(60)), baseline: engine.baselineHR, sessionStart: startDate)
        LabelStore.add(LabeledExample(window: window, label: label))
    }

    // MARK: - AI

    /// 每 judgeInterval 秒把这段数据汇总发给后端
    private func requestJudgment() {
        guard let startDate else { return }
        let n = Int(AIConfig.judgeInterval)
        let window = WindowSummary.make(from: Array(samples.suffix(n)), baseline: engine.baselineHR, sessionStart: startDate)
        windows.append(window)
        let req = JudgeRequest(window: window, examples: LabelStore.examples, recent: Array(judgments.suffix(3)))
        let sync = self.sync
        Task {
            let result = await sync.submit(req)
            await MainActor.run { self.apply(result) }
        }
    }

    /// 离线期间每 5 秒看一眼：退避时间到了就重发（没到时 flush 立刻返回，不发请求）
    private func retryPendingIfNeeded() {
        guard pendingJudgments > 0, Int(elapsed) % 5 == 0 else { return }
        let sync = self.sync
        Task {
            let result = await sync.flush()
            await MainActor.run { self.apply(result) }
        }
    }

    /// 把送达的判断按窗口顺序记下来；最新窗口的判断显示在圆环下面
    @MainActor private func apply(_ result: SyncResult) {
        for d in result.delivered {
            judgments.append(d.judgment)
            timeline.append(JudgedWindow(minute: d.request.window.minuteOfSession, judgment: d.judgment))
            if d.request.window == windows.last { aiJudgment = d.judgment }
        }
        pendingJudgments = result.pending
        if result.pending > 0 {
            aiError = "AI 离线 · 排队 \(result.pending) 条"
        } else if result.lastError != nil && result.delivered.isEmpty {
            aiError = "AI 暂时连不上"
        } else {
            aiError = nil
        }
    }

    private func requestReview() async {
        let req = ReviewRequest(
            durationMinutes: Int(elapsed / 60),
            averageScore: averageScore,
            focusedRatio: focusedRatio,
            awayCount: awayCount,
            awayMinutes: (awaySeconds / 6).rounded() / 10,
            windows: windows,
            judgments: judgments
        )
        let review = try? await AIClient.review(req)
        await MainActor.run {
            self.aiReview = review
            self.aiReviewLoading = false
        }
    }

    // MARK: - 汇总（结束页用）

    var averageScore: Double? { SessionStats.averageScore(samples) }

    /// 分数 ≥ 70 的时间占比
    var focusedRatio: Double? { SessionStats.focusedRatio(samples) }

    // MARK: - 传感器

    private func startMotion() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1 / motionHz
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.userAcceleration else { return }
            let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            self.motionWindow.append(mag)
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
        if engine.setAway(away, at: elapsed) { syncAway() }
    }

    private func syncAway() {
        isAway = engine.away.isAway
        awayCount = engine.away.awayCount
        awaySeconds = engine.away.awaySeconds
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
        motion = motionWindow.mean
        #if targetEnvironment(simulator)
        simulateSensors()
        #endif

        // 校准 / 打分 / 离座计时 / 恢复期都在 FocusEngine.tick 里（见 FlowbeatCore 的单元测试）
        let result = engine.tick(elapsed: elapsed, heartRate: heartRate, motion: motion)
        if result.didFinishCalibration { phase = .running }
        score = engine.score
        syncAway()

        samples.append(FocusSample(t: Date(), heartRate: heartRate, motion: motion,
                                   score: result.sampleScore, label: pendingLabel, away: isAway))
        pendingLabel = nil

        if phase == .running, elapsed - lastJudgeAt >= AIConfig.judgeInterval {
            lastJudgeAt = elapsed
            requestJudgment()
        } else {
            retryPendingIfNeeded()
        }
    }

    var calibrationSeconds: TimeInterval { engine.calibrationSeconds }

    #if targetEnvironment(simulator)
    /// 模拟器没有真传感器：校准后按 60 秒循环造假数据——专注 35 秒 → 走神 10 秒 → 起身走路 15 秒。
    /// 真机不会编译这段。
    private func simulateSensors() {
        let afterCalibration = elapsed - engine.calibrationSeconds
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
        let encoder = FlowbeatJSON.sessionEncoder
        let record = SessionRecord(samples: samples, windows: windows, judgments: judgments, review: aiReview,
                                   timeline: timeline)
        if let data = try? encoder.encode(record) {
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
