import AppIntents
import FlowbeatCore

// Siri / 快捷指令 / Apple Watch Ultra 操作按钮：开始专注、开始番茄钟、结束专注。
//
// 操作按钮：系统「设置 → 操作按钮 → 快捷指令」可以选任何快捷指令，所以这些 App Shortcuts 不用别的代码就能绑到操作按钮上。
// 没有采用 StartWorkoutIntent（操作按钮的「体能训练」类别）：Flowbeat 虽然借用 Mind & Body 体能训练读心率，
// 但它不是体能训练 app，把专注包装成体能训练去占这个入口，审核上说不过去（见 docs/appstore/review-notes.md）。

/// 开始一次专注（自由计时）。要打开 app：HealthKit workout 必须从前台开始，用户也要看到校准倒计时。
struct StartFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Focus Session"
    static let description = IntentDescription("Starts a free-run focus session in Flowbeat.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await FocusIntentRunner.start(.free)
    }
}

/// 开始番茄钟（工作 / 休息时长用设置里的）
struct StartPomodoroIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Pomodoro"
    static let description = IntentDescription("Starts a Pomodoro focus session with your work and break lengths.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await FocusIntentRunner.start(.pomodoro)
    }
}

/// 结束当前专注、保存存档。不用打开 app：专注进行中 app 本来就在后台运行（workout session）。
struct StopFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Focus Session"
    static let description = IntentDescription("Ends the running focus session and saves it.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = FocusSession.shared
        guard session.phase == .calibrating || session.phase == .running else {
            return .result(dialog: IntentDialog("No focus session is running."))
        }
        await session.stop()
        let minutes = session.focusedMinutes
        return .result(dialog: IntentDialog("Session saved. \(minutes) min focused."))
    }
}

@MainActor
enum FocusIntentRunner {
    static func start(_ mode: SessionMode) async throws -> some IntentResult & ProvidesDialog {
        let session = FocusSession.shared
        switch session.phase {
        case .calibrating, .running:
            return .result(dialog: IntentDialog("A focus session is already running."))
        case .finished:
            session.reset()   // 上一次的结束页还开着：直接开始新的一次
        case .idle:
            break
        }
        await session.start(mode: mode)
        guard session.phase == .calibrating else {
            // 多半是「健康」权限被拒（开始页会显示具体原因和去哪里打开）
            return .result(dialog: IntentDialog("Flowbeat couldn't start. Open the app to see why."))
        }
        return .result(dialog: mode == .pomodoro ? IntentDialog("Pomodoro started. Sit still for the calibration.")
                                                 : IntentDialog("Focus session started. Sit still for the calibration."))
    }
}

/// 不用用户自己建快捷指令：装好就能对 Siri 说，也能在「快捷指令」app 和操作按钮里选
struct FlowbeatShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartFocusIntent(),
                    phrases: ["Start focus in \(.applicationName)",
                              "Start a focus session in \(.applicationName)"],
                    shortTitle: "Start Focus",
                    systemImageName: "play.fill")
        AppShortcut(intent: StartPomodoroIntent(),
                    phrases: ["Start a Pomodoro in \(.applicationName)"],
                    shortTitle: "Start Pomodoro",
                    systemImageName: "timer")
        AppShortcut(intent: StopFocusIntent(),
                    phrases: ["Stop focus in \(.applicationName)",
                              "End my \(.applicationName) session"],
                    shortTitle: "Stop Focus",
                    systemImageName: "stop.fill")
    }
}
