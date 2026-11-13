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
    /// 本次专注的名字（开始时间，ISO 8601，冒号换成 -）：存档 Documents/sessions/<name>.json 和
    /// 待发队列 Application Support/Flowbeat/judge-queue/<name>.json 同名
    private var sessionName: String?
    private var tickTimer: Timer?
    private var pendingLabel: String?
    /// 活动识别 / 计步有没有真的启动过。没启动就别调 stop：在模拟器里实测，对没启动的
    /// CMMotionActivityManager / CMPedometer 调 stop 也会弹「运动与健身」授权窗（演示模式结束时冒出来）
    private var activityTrackingStarted = false

    // AI 判断（后端 + 大模型）。只在 FLOWBEAT_AI（Debug）build 里会有值；
    // Release 里 transport 是 nil，这些永远保持初始值，不发任何请求，本地规则照常工作。
    /// 网络客户端：只能经过功能开关构造（AppFeatures.makeTransport），AI 关闭时是 nil
    private let transport: (any JudgeTransport)? = AppFeatures.makeTransport()
    var aiEnabled: Bool { transport != nil }
    @Published private(set) var aiJudgment: Judgment?
    @Published private(set) var aiReview: Review?
    @Published private(set) var aiReviewLoading = false
    @Published private(set) var aiError: String?
    private(set) var windows: [WindowSummary] = []
    private(set) var judgments: [Judgment] = []
    private(set) var timeline: [JudgedWindow] = []
    /// 每个窗口在第几秒结束（判断可能离线排队后才回来，用它把判断放回时间轴的正确位置）
    private var windowEnds: [WindowSummary: TimeInterval] = [:]
    private var lastJudgeAt: TimeInterval = 0
    /// 最近 6 小时的 HRV（SDNN）读数。没授权 / 没读数时是空数组，摘要里就不带 HRV
    private var hrvSamples: [HRVSample] = []
    /// 所有判断请求都走这个队列：在线时等于直接发；连不上后端时排队，按 15 s → 30 s → … ≤ 5 min 退避重试，最多 30 条
    /// AI 关闭时是 nil。队列每次变化都落盘（JudgeQueueStore），app 被杀掉后下次启动接着发。
    private var sync: JudgeSync?
    #if FLOWBEAT_AI
    private let queueStore = JudgeQueueStore(directory: JudgeQueueStore.defaultDirectory())
    /// 正在补发上次剩下的队列（防止启动和结束时同时补发同一份）
    private var drainTask: Task<Void, Never>?
    #endif

    override init() {
        super.init()
        #if FLOWBEAT_AI
        Task { @MainActor in self.drainLeftovers() }   // 启动时：上次没发完的窗口（≤ 1 小时）补发，判断补进对应的存档
        #endif
    }
    /// 还在排队等发送的窗口数（> 0 时 UI 显示「离线」）
    @Published private(set) var pendingJudgments = 0

    // MARK: - 授权

    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            await setError(String(localized: "Health data isn't available on this device."))
            return false
        }
        // 只读心率。HRV 只给 AI 判断用（可选，用户不给也能用），所以只有 AI build 才申请（数据最小化）
        var read: Set<HKObjectType> = [HKQuantityType(.heartRate)]
        if aiEnabled { read.insert(HKQuantityType(.heartRateVariabilitySDNN)) }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        do {
            try await healthStore.requestAuthorization(toShare: share, read: read)
            // 弹窗被关掉 / 点了不允许时，上面不会抛错，要自己再查一次
            guard healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                await setError(String(localized: "Allow Health access: Settings → Health → Apps → Flowbeat."))
                return false
            }
            await MainActor.run { self.errorMessage = nil }
            return true
        } catch {
            await setError(String(localized: "Couldn't request Health access: \(error.localizedDescription)"))
            return false
        }
    }

    // MARK: - 开始 / 结束

    func start() async {
        #if targetEnvironment(simulator)
        // 模拟器 -demo：传感器本来就是模拟的，跳过 HealthKit 授权弹窗和 workout，直接开始（方便自动化跑 demo）
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            await MainActor.run { self.beginSession(at: Date()) }
            return
        }
        #endif
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

            await MainActor.run { self.beginSession(at: now) }
        } catch {
            await setError(String(localized: "Couldn't start the session: \(error.localizedDescription)"))
        }
    }

    /// 清空上一次的状态，开始校准和计时
    @MainActor private func beginSession(at now: Date) {
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
        self.windowEnds = [:]
        let name = Self.sessionName(for: now)
        self.sessionName = name
        #if FLOWBEAT_AI
        // 每次专注一个新队列（一个文件）；AI 关闭时是 nil
        let store = queueStore
        self.sync = transport.map {
            JudgeSync(transport: $0, onChange: { q in try? store.save(q, session: name) })
        }
        #endif
        self.pendingJudgments = 0
        self.lastJudgeAt = 0
        self.hrvSamples = []
        self.startDate = now
        self.phase = .calibrating
        #if targetEnvironment(simulator)
        // 演示模式里动作 / 走路 / 步数全由 simulateSensors 模拟，不碰 CoreMotion，
        // 也就不会弹「活动与体能训练」权限窗（它会挡住自动化 demo）
        if !ProcessInfo.processInfo.arguments.contains("-demo") {
            self.startActivityTracking(from: now)
            self.startMotion()
        }
        #else
        self.startActivityTracking(from: now)
        self.startMotion()
        #endif
        if aiEnabled { self.refreshHRV() }   // HRV 只给 AI 摘要用
        self.startTicking()
    }

    func stop() async {
        await MainActor.run {
            tickTimer?.invalidate()
            tickTimer = nil
            motionManager.stopDeviceMotionUpdates()
            if activityTrackingStarted {
                activityManager.stopActivityUpdates()
                pedometer.stopUpdates()
                activityTrackingStarted = false
            }
        }
        workoutSession?.end()
        if let builder {
            try? await builder.endCollection(at: Date())
            builder.discardWorkout()   // 不往「健康」里塞一条假体能训练
        }
        workoutSession = nil
        builder = nil
        let aiOn = aiEnabled
        await MainActor.run {
            self.phase = .finished
            self.aiReviewLoading = aiOn
        }
        if let sync {
            // 结束前把排队的窗口最后试一次（不等退避），这样复盘能用上尽量多的判断
            let final = await sync.flush(ignoringBackoff: true)
            await MainActor.run { self.apply(final) }
            await requestReview()
        }
        saveSamples()
        #if FLOWBEAT_AI
        await MainActor.run { self.drainLeftovers() }   // 结束后还有没发出去的，下次启动或下次结束时再试
        #endif
    }

    func reset() { phase = .idle }

    /// 手动打标签：下一秒的记录会带上它（存进本次的 JSON）；AI build 里还把最近 1 分钟存成你的 few-shot 例子
    func mark(_ label: String) {
        pendingLabel = label
        #if FLOWBEAT_AI
        guard aiEnabled, let startDate, !samples.isEmpty else { return }
        let window = WindowSummary.make(from: Array(samples.suffix(60)), baseline: engine.baselineHR,
                                        sessionStart: startDate, hrv: hrvSamples)
        LabelStore.add(LabeledExample(window: window, label: label))
        #endif
    }

    // MARK: - AI

    /// 每 judgeInterval 秒把这段数据汇总发给后端
    private func requestJudgment() {
        #if FLOWBEAT_AI
        guard let startDate, let sync else { return }
        let n = Int(AppFeatures.judgeInterval)
        let window = WindowSummary.make(from: Array(samples.suffix(n)), baseline: engine.baselineHR,
                                        sessionStart: startDate, hrv: hrvSamples)
        windows.append(window)
        windowEnds[window] = elapsed
        let req = JudgeRequest(window: window, examples: LabelStore.examples, recent: Array(judgments.suffix(3)))
        Task {
            let result = await sync.submit(req)
            await MainActor.run { self.apply(result) }
        }
        #endif
    }

    /// 读最近 6 小时的 HRV（SDNN）。手表只是偶尔在后台测一次，所以开始时读一次、之后每 5 分钟再读一次就够了。
    /// 没授权时 HealthKit 不报错，只是返回空结果（隐私设计：app 无法知道用户拒绝了读取），这里就当「没有 HRV」。
    private func refreshHRV() {
        let type = HKQuantityType(.heartRateVariabilitySDNN)
        let since = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-HRVSummary.defaultLookback), end: nil)
        let newestFirst = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: type, predicate: since, limit: 10, sortDescriptors: [newestFirst]) { [weak self] _, results, _ in
            let ms = HKUnit.secondUnit(with: .milli)
            let list = (results as? [HKQuantitySample] ?? []).map {
                HRVSample(date: $0.startDate, sdnnMs: $0.quantity.doubleValue(for: ms))
            }
            DispatchQueue.main.async { self?.hrvSamples = list }
        }
        healthStore.execute(query)
    }

    /// 离线期间每 5 秒看一眼：退避时间到了就重发（没到时 flush 立刻返回，不发请求）
    private func retryPendingIfNeeded() {
        guard pendingJudgments > 0, Int(elapsed) % 5 == 0 else { return }
        guard let sync else { return }
        Task {
            let result = await sync.flush()
            await MainActor.run { self.apply(result) }
        }
    }

    /// 把送达的判断按窗口顺序记下来；最新窗口的判断显示在圆环下面
    @MainActor private func apply(_ result: SyncResult) {
        for d in result.delivered {
            judgments.append(d.judgment)
            timeline.append(JudgedWindow(minute: d.request.window.minuteOfSession, judgment: d.judgment,
                                         endSeconds: windowEnds[d.request.window].map { ($0 * 10).rounded() / 10 }))
            if d.request.window == windows.last { aiJudgment = d.judgment }
        }
        pendingJudgments = result.pending
        if result.pending > 0 {
            aiError = String(localized: "AI offline · \(result.pending) queued")
        } else if result.lastError != nil && result.delivered.isEmpty {
            aiError = String(localized: "AI unreachable")
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
        let review = try? await transport?.review(req)
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
        activityTrackingStarted = true
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

        if aiEnabled, phase == .running, elapsed - lastJudgeAt >= AppFeatures.judgeInterval {
            lastJudgeAt = elapsed
            requestJudgment()
        } else {
            retryPendingIfNeeded()
        }
        if aiEnabled, phase == .running, Int(elapsed) % 300 == 0 { refreshHRV() }
    }

    var calibrationSeconds: TimeInterval { engine.calibrationSeconds }

    #if targetEnvironment(simulator)
    private var lastDemoLabelSecond = -1

    /// 模拟器没有真传感器：校准后按 60 秒循环造假数据——专注 35 秒 → 走神 10 秒 → 起身走路 15 秒。
    /// 真机不会编译这段。
    private func simulateSensors() {
        let afterCalibration = elapsed - engine.calibrationSeconds
        let t = afterCalibration > 0 ? afterCalibration.truncatingRemainder(dividingBy: 60) : 0
        // -demoLabels：每个循环在专注段第 20 秒、走神段第 40 秒自动打一次标签（用来生成带标签的示例存档）
        if ProcessInfo.processInfo.arguments.contains("-demoLabels"), afterCalibration > 0 {
            let sec = Int(afterCalibration)
            if sec != lastDemoLabelSecond, sec % 60 == 20 || sec % 60 == 40 {
                lastDemoLabelSecond = sec
                mark(sec % 60 == 20 ? "focused" : "distracted")
            }
        }
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
        let name = sessionName ?? Self.sessionName(for: samples[0].t)
        let encoder = FlowbeatJSON.sessionEncoder
        let record = SessionRecord(samples: samples, windows: windows, judgments: judgments, review: aiReview,
                                   timeline: timeline)
        let url = dir.appendingPathComponent("\(name).json")
        if let data = try? encoder.encode(record), (try? data.write(to: url, options: .atomic)) != nil {
            PhoneSync.shared.send(sessionFile: url)   // 有 iPhone 端就同步过去画时间线
        }
    }

    static func sessionName(for start: Date) -> String {
        ISO8601DateFormatter().string(from: start).replacingOccurrences(of: ":", with: "-")
    }

    static var sessionsDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sessions", isDirectory: true)
    }

    #if FLOWBEAT_AI
    /// 补发以前的专注留下的待发队列（不包括正在进行的这次）。送达的判断补进那次的存档 JSON。
    /// 还是发不出去就留在磁盘上（最多 1 小时，过期的读的时候就丢掉）。
    @MainActor private func drainLeftovers() {
        guard let transport, drainTask == nil else { return }
        let store = queueStore
        let current = (phase == .calibrating || phase == .running) ? sessionName : nil
        drainTask = Task.detached { [weak self] in
            for name in store.sessions() where name != current {
                guard let q = store.load(session: name) else { continue }
                let sync = JudgeSync(transport: transport, queue: q, onChange: { try? store.save($0, session: name) })
                let r = await sync.flush(ignoringBackoff: true)
                if !r.delivered.isEmpty { Self.appendToArchive(name, r.delivered) }
            }
            if let me = self { await MainActor.run { me.drainTask = nil } }
        }
    }

    /// 把晚到的判断补进 Documents/sessions/<name>.json（原子写）。存档不存在（专注中途被杀、没存档）就算了。
    private static func appendToArchive(_ name: String, _ delivered: [(request: JudgeRequest, judgment: Judgment)]) {
        guard let url = sessionsDirectory?.appendingPathComponent("\(name).json"),
              let data = try? Data(contentsOf: url),
              let record = try? FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: data),
              let out = try? FlowbeatJSON.sessionEncoder.encode(record.appendingLateJudgments(delivered))
        else { return }
        try? out.write(to: url, options: .atomic)
    }
    #endif

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
