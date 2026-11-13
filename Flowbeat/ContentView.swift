import SwiftUI
import WatchKit
import FlowbeatCore

// MARK: - 配色

enum Theme {
    /// 品牌渐变：薄荷绿 → 青
    static let flow: [Color] = [.mint, .cyan]

    /// 分数 → 颜色：≥70 心流（绿），40–70 分心（黄），<40 走神（橙红）
    static func colors(for score: Double?) -> [Color] {
        guard let s = score else { return [.gray, .gray] }
        if s >= 70 { return flow }
        if s >= 40 { return [.yellow, .orange] }
        return [.orange, .pink]
    }

    static func color(for score: Double?) -> Color { colors(for: score)[0] }
}

// MARK: - 根视图

struct ContentView: View {
    @EnvironmentObject var session: FocusSession
    @EnvironmentObject var permissions: PermissionCenter
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOnboarding = ContentView.needsOnboarding()

    var body: some View {
        Group {
            if showOnboarding {
                // 首次启动：先说明，再在最后一页请求权限
                OnboardingView(mode: .firstLaunch) {
                    OnboardingState(store: UserDefaults.standard).complete()
                    showOnboarding = false
                }
            } else {
                NavigationStack {
                    switch session.phase {
                    case .idle: StartView()
                    case .calibrating, .running: RunningView()
                    case .finished: SummaryView()
                    }
                }
            }
        }
        // 用户可能去「设置」里改了权限，回到 app 时重新读一次
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permissions.refresh() }
        }
    }

    static func needsOnboarding() -> Bool {
        #if targetEnvironment(simulator)
        // 演示模式（-demo）直接进开始页，方便自动化截图
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demo") || args.contains("-demoDenied") { return false }
        #endif
        return OnboardingState(store: UserDefaults.standard).needsOnboarding
    }
}

// MARK: - 通用组件：渐变圆环

struct Ring<Center: View>: View {
    var progress: Double
    var colors: [Color]
    var lineWidth: CGFloat = 11
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(
                    AngularGradient(colors: colors + [colors[0]], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[0].opacity(0.5), radius: 6)
                .animation(.easeInOut(duration: 0.8), value: progress)
            center
        }
    }
}

// MARK: - 开始页

struct StartView: View {
    @EnvironmentObject var session: FocusSession
    @EnvironmentObject var permissions: PermissionCenter
    @State private var breathe = false
    @State private var showAbout = false

    var body: some View {
        ScrollView {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(LinearGradient(colors: Theme.flow, startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 5)
                    .scaleEffect(breathe ? 1 : 0.86)
                    .opacity(breathe ? 1 : 0.5)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: Theme.flow, startPoint: .leading, endPoint: .trailing))
            }
            .frame(width: 64, height: 64)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever()) { breathe = true }
            }

            VStack(spacing: 0) {
                Text("Flowbeat").font(.system(.title2, design: .rounded, weight: .bold))
                Text(verbatim: "FLOWBEAT").font(.system(size: 10, weight: .semibold)).tracking(3)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    await session.start()
                    permissions.refresh()
                }
            } label: {
                Label("Start Focus", systemImage: "play.fill").font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .disabled(!permissions.readiness.canStart)

            PermissionNotices()

            if let err = session.errorMessage {
                Text(err).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showAbout = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel(Text("About Flowbeat"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(Text("Settings"))
            }
        }
        .sheet(isPresented: $showAbout) {
            OnboardingView(mode: .about) { showAbout = false }
        }
        .containerBackground(Color.mint.gradient.opacity(0.22), for: .navigation)
        #if targetEnvironment(simulator)
        // 模拟器带 -demo 启动参数时自动开始，方便截图检查界面；
        // 再加 -demoStopAfter <秒> 会自动结束并存档（用来生成 iPhone 端的示例 session）
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard args.contains("-demo") else { return }
            await session.start()
            if let i = args.firstIndex(of: "-demoStopAfter"), i + 1 < args.count, let secs = Double(args[i + 1]) {
                // 不能直接在 .task 里 sleep：开始后 StartView 就消失了，.task 被取消，sleep 立刻抛错 → 马上 stop。
                // 用一个不跟视图生命周期绑定的 Task。
                Task { [session] in
                    try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                    await session.stop()
                }
            }
        }
        #endif
    }
}

// MARK: - 进行中：上下翻页（第 1 页看数据，第 2 页操作）

struct RunningView: View {
    @EnvironmentObject var session: FocusSession

    var body: some View {
        TabView {
            MetricsPage()
            ControlsPage()
        }
        .tabViewStyle(.verticalPage)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text(timeString(session.elapsed))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(stateColor)
            }
        }
    }

    private var stateColor: Color {
        if session.isAway { return .cyan }
        if session.phase == .calibrating { return .white }
        return Theme.color(for: session.score)
    }
}

struct MetricsPage: View {
    @EnvironmentObject var session: FocusSession

    var body: some View {
        VStack(spacing: 6) {
            ring.frame(width: 104, height: 104)
            HStack {
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    Text(session.heartRate.map { "\(Int($0))" } ?? "--").monospacedDigit()
                    Text("BPM").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                MotionIndicator(motion: session.motion)
            }
            .font(.system(.footnote, design: .rounded, weight: .medium))
            .padding(.horizontal, 4)

            // AI 那一行只在 AI build（Debug）里出现；上架版没有 AI，也不联网
            if showNudgeBanner {
                NudgeBanner()
            } else if session.aiEnabled {
                AILine()
            }
        }
        .containerBackground(background.gradient.opacity(0.28), for: .tabView)
    }

    @ViewBuilder private var ring: some View {
        if session.isAway {
            Ring(progress: 1, colors: [.cyan, .blue]) {
                VStack(spacing: 2) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 30))
                        .foregroundStyle(.cyan)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("Away").font(.system(.footnote, weight: .semibold))
                    Text("Resumes when you sit").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        } else if session.phase == .calibrating {
            let left = max(0, Int(session.calibrationSeconds - session.elapsed))
            Ring(progress: session.elapsed / session.calibrationSeconds, colors: [.white.opacity(0.5), .white]) {
                VStack(spacing: 0) {
                    Text("\(left)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("Calibrating · sit still").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        } else {
            Ring(progress: (session.score ?? 0) / 100, colors: Theme.colors(for: session.score)) {
                VStack(spacing: 0) {
                    Text(session.score.map { "\(Int($0))" } ?? "--")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.color(for: session.score))
                        .contentTransition(.numericText())
                        .animation(.default, value: session.score.map(Int.init))
                    Text(stateText).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 刚提醒过（8 秒内）：在圆环下面说明为什么震了一下
    private var showNudgeBanner: Bool {
        guard let at = session.lastNudgeAt else { return false }
        return session.elapsed - at < 8
    }

    private var stateText: LocalizedStringKey {
        guard let s = session.score else { return "Focus score" }
        return s >= 70 ? "In flow" : (s >= 40 ? "A bit distracted" : "Off track")
    }

    private var background: Color {
        if session.isAway { return .cyan }
        if session.phase == .calibrating { return .gray }
        return Theme.color(for: session.score)
    }
}

/// AI 的最新判断：一句理由。还没轮到第一次判断 / 连不上时给提示
struct AILine: View {
    @EnvironmentObject var session: FocusSession

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .foregroundStyle(color)
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(session.aiJudgment == nil ? .secondary : .primary)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.08), in: Capsule())
        .animation(.default, value: session.aiJudgment)
    }

    private var text: String {
        // 离线排队时优先告诉用户，否则会一直显示一条过时的理由
        if session.pendingJudgments > 0, let e = session.aiError { return e }
        if let j = session.aiJudgment { return j.reason }
        if let e = session.aiError { return e }
        return session.phase == .calibrating ? String(localized: "AI waits for calibration")
                                             : String(localized: "AI is watching…")
    }

    private var color: Color {
        switch session.aiJudgment?.state {
        case "focused": return .mint
        case "distracted": return .orange
        case "away": return .cyan
        default: return .secondary
        }
    }
}

/// 走神提醒后显示几秒：告诉用户刚才那一下震动是什么
struct NudgeBanner: View {
    var body: some View {
        Label("Drifting? Back to it", systemImage: "hand.tap.fill")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.15), in: Capsule())
            .transition(.opacity)
    }
}

/// 手腕动作：用「稳 / 小动 / 活跃」+ 三格条代替看不懂的数字
struct MotionIndicator: View {
    let motion: Double

    private var level: Int { motion < 0.03 ? 1 : (motion < 0.10 ? 2 : 3) }
    private var text: LocalizedStringKey { ["Still", "Slight", "Active"][level - 1] }
    private var color: Color { [Color.mint, .yellow, .orange][level - 1] }

    var body: some View {
        HStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(1...3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i <= level ? color : .white.opacity(0.2))
                        .frame(width: 3, height: CGFloat(4 + i * 3))
                }
            }
            Text(text).foregroundStyle(color)
        }
        .animation(.easeInOut, value: level)
    }
}

struct ControlsPage: View {
    @EnvironmentObject var session: FocusSession
    /// 刚打的标签（"focused" / "distracted"），1.5 秒后清空
    @State private var marked: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(markedText)
                .font(.footnote)
                .foregroundStyle(marked == nil ? .secondary : .primary)
                .animation(.default, value: marked)

            HStack(spacing: 6) {
                labelButton("Focused", icon: "brain.head.profile", color: .mint, tag: "focused")
                labelButton("Distracted", icon: "cloud.fog.fill", color: .orange, tag: "distracted")
            }

            Button(role: .destructive) {
                Task { await session.stop() }
            } label: {
                Label("End", systemImage: "stop.fill")
            }
            .tint(.red)
        }
        .containerBackground(Color.gray.gradient.opacity(0.2), for: .tabView)
    }

    private var markedText: LocalizedStringKey {
        switch marked {
        case "focused": return "Marked: Focused"
        case "distracted": return "Marked: Distracted"
        default: return "How are you right now?"
        }
    }

    private func labelButton(_ title: LocalizedStringKey, icon: String, color: Color, tag: String) -> some View {
        Button {
            session.mark(tag)
            Haptics.label()
            marked = tag
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if marked == tag { marked = nil }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .tint(color)
    }
}

// MARK: - 结束页

struct SummaryView: View {
    @EnvironmentObject var session: FocusSession

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Ring(progress: (session.averageScore ?? 0) / 100,
                     colors: Theme.colors(for: session.averageScore), lineWidth: 9) {
                    VStack(spacing: 0) {
                        Text(session.averageScore.map { "\(Int($0))" } ?? "--")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.color(for: session.averageScore))
                        Text("Average focus").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)

                VStack(spacing: 0) {
                    stat("clock.fill", .white, "Duration", Text(verbatim: timeString(session.elapsed)))
                    stat("sparkles", .mint, "Time in flow",
                         Text(verbatim: session.focusedRatio.map { "\(Int($0 * 100))%" } ?? "--"))
                    stat("figure.walk", .cyan, "Away", Text("\(session.awayCount)× · \(timeString(session.awaySeconds))"))
                    stat("shoeprints.fill", .orange, "Steps", Text(verbatim: "\(session.steps)"))
                    if session.nudgeCount > 0 {
                        stat("hand.tap.fill", .yellow, "Nudges", Text(verbatim: "\(session.nudgeCount)"))
                    }
                }
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                aiReviewCard

                Button("Done") { session.reset() }
                    .buttonStyle(.borderedProminent)
                    .tint(.mint)
            }
        }
        .navigationTitle("Summary")
        .containerBackground(Theme.color(for: session.averageScore).gradient.opacity(0.22), for: .navigation)
    }

    @ViewBuilder private var aiReviewCard: some View {
        if session.aiReviewLoading {
            HStack(spacing: 6) {
                ProgressView().frame(width: 16, height: 16)
                Text("AI reviewing…").font(.footnote).foregroundStyle(.secondary)
            }
        } else if let r = session.aiReview {
            VStack(alignment: .leading, spacing: 6) {
                Label("AI review", systemImage: "sparkles")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(.mint)
                Text(r.summary).font(.footnote)
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    Text(r.tip)
                }
                .font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func stat(_ icon: String, _ color: Color, _ k: LocalizedStringKey, _ v: Text) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            Text(k).foregroundStyle(.secondary)
            Spacer()
            v.monospacedDigit()
        }
        .font(.system(.footnote, design: .rounded))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

func timeString(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%02d:%02d", s / 60, s % 60)
}
