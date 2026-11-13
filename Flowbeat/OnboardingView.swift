import SwiftUI
import FlowbeatCore

/// 首次启动说明（也从开始页左上角的 ⓘ 再次打开）。
///
/// 三页说明：做什么 → 不是医疗设备 → 数据只在手表上。
/// 首次启动多一页「需要的权限」：用户点「继续」才弹系统授权窗（先解释、后请求）。
struct OnboardingView: View {
    enum Mode { case firstLaunch, about }

    let mode: Mode
    var onFinish: () -> Void = {}

    @EnvironmentObject var permissions: PermissionCenter
    @EnvironmentObject var session: FocusSession
    @State private var requesting = false
    @State private var pageIndex = OnboardingView.initialPage()

    var body: some View {
        TabView(selection: $pageIndex) {
            page(icon: "waveform.path.ecg", color: .mint, title: "Flowbeat",
                 body: "Estimates how focused you are from your heart rate and wrist motion, as a 0–100 score.")
                .tag(0)
            page(icon: "info.circle", color: .orange, title: "Not a medical device",
                 body: "The score is an estimate for personal reflection. Flowbeat does not diagnose, treat or monitor any health condition.")
                .tag(1)
            if session.aiEnabled {
                // 只有 Debug（AI）build 会出现这一页；上架版没有网络代码
                page(icon: "network", color: .yellow, title: "Developer build",
                     body: "AI judge is on: every 2 minutes a summary of your heart rate and motion is sent to the backend configured in this build.")
                    .tag(2)
            } else {
                page(icon: "lock.applewatch", color: .cyan, title: "Stays on your watch",
                     body: "Heart rate, motion and your sessions are stored only on this Apple Watch. No account, no servers, no tracking.")
                    .tag(2)
            }
            switch mode {
            case .firstLaunch: permissionsPage.tag(3)
            case .about: aboutPage.tag(3)
            }
        }
        .tabViewStyle(.verticalPage)
    }

    private func page(icon: String, color: Color, title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        ScrollView {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(.headline, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 4)
        }
        .containerBackground(color.gradient.opacity(0.2), for: .tabView)
    }

    private var permissionsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Next, Flowbeat asks for:")
                    .font(.system(.headline, design: .rounded))
                Label("Heart rate, from Health", systemImage: "heart.fill")
                    .foregroundStyle(.red)
                Label("Motion & Fitness, to pause while you walk", systemImage: "figure.walk")
                    .foregroundStyle(.cyan)
                Text("A focus session runs a Mind & Body workout to read your heart rate. It is discarded and never saved to Health.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    requesting = true
                    Task {
                        await permissions.requestAll(includeHRV: session.aiEnabled)
                        requesting = false
                        onFinish()   // 无论允许还是拒绝都进入开始页，开始页会说明下一步
                    }
                } label: {
                    if requesting { ProgressView() } else { Text("Continue") }
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)
                .disabled(requesting)
            }
            .font(.footnote)
        }
        .containerBackground(Color.mint.gradient.opacity(0.2), for: .tabView)
    }

    private var aboutPage: some View {
        VStack(spacing: 6) {
            Text(verbatim: "Flowbeat \(Self.version)")
                .font(.system(.headline, design: .rounded))
            Text("Not a medical device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Close", action: onFinish)
                .tint(.mint)
        }
        .containerBackground(Color.gray.gradient.opacity(0.2), for: .tabView)
    }

    /// 模拟器截图用：-onboardingPage N 直接打开第 N 页（真机不编译）
    static func initialPage() -> Int {
        #if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-onboardingPage"), i + 1 < args.count, let n = Int(args[i + 1]) { return n }
        #endif
        return 0
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

/// 开始页上的权限提示：拒绝了就告诉用户去哪里打开，并能再检查一次——不是死胡同
struct PermissionNotices: View {
    @EnvironmentObject var permissions: PermissionCenter
    @EnvironmentObject var session: FocusSession

    var body: some View {
        let notices = permissions.readiness.notices
        if notices.contains(.healthUnavailable) {
            notice("heart.slash", .red, "Health data isn't available on this device.")
        }
        if notices.contains(.healthDenied) {
            VStack(spacing: 4) {
                notice("heart.slash", .red,
                       "Heart rate is off, so Flowbeat can't estimate focus. Turn it on in the Health app on your iPhone (Sharing → Apps → Flowbeat) or in Settings → Health on your watch.")
                Button("Check again") {
                    Task { await permissions.requestAll(includeHRV: session.aiEnabled) }
                }
                .font(.footnote)
            }
        }
        if notices.contains(.motionDenied) {
            notice("figure.walk", .yellow,
                   "Motion & Fitness is off, so walking won't pause scoring. Settings → Privacy & Security → Motion & Fitness.")
        }
    }

    private func notice(_ icon: String, _ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
