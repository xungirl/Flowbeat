import SwiftUI

struct ContentView: View {
    @EnvironmentObject var session: FocusSession

    var body: some View {
        switch session.phase {
        case .idle: StartView()
        case .calibrating, .running: RunningView()
        case .finished: SummaryView()
        }
    }
}

// MARK: - 开始页

struct StartView: View {
    @EnvironmentObject var session: FocusSession

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 36))
                .foregroundStyle(.mint)
            Text("专注时段").font(.headline)
            Button("开始") { Task { await session.start() } }
                .buttonStyle(.borderedProminent)
                .tint(.mint)
            if let err = session.errorMessage {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
        // 一打开就先要授权，别等点「开始」才弹
        .task { _ = await session.requestAuthorization() }
    }
}

// MARK: - 进行中

struct RunningView: View {
    @EnvironmentObject var session: FocusSession

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if session.phase == .calibrating {
                    Text("校准中").font(.headline)
                    Text("安静坐着 \(max(0, Int(session.calibrationSeconds - session.elapsed))) 秒")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(session.score.map { "\(Int($0))" } ?? "--")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(color(for: session.score))
                    Text("专注指数").font(.footnote).foregroundStyle(.secondary)
                }

                HStack {
                    Label(session.heartRate.map { "\(Int($0))" } ?? "--", systemImage: "heart.fill")
                        .foregroundStyle(.red)
                    Spacer()
                    Label(String(format: "%.3f", session.motion), systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)

                Text(timeString(session.elapsed)).font(.caption).monospacedDigit()

                // 打标签：以后训练个人模型的「正确答案」
                HStack {
                    Button("专注") { session.mark("focused") }.tint(.mint)
                    Button("走神") { session.mark("distracted") }.tint(.orange)
                }
                .font(.footnote)

                Button("结束", role: .destructive) { Task { await session.stop() } }
            }
        }
    }

    private func color(for score: Double?) -> Color {
        guard let s = score else { return .secondary }
        return s >= 70 ? .mint : (s >= 40 ? .yellow : .orange)
    }
}

// MARK: - 结束页

struct SummaryView: View {
    @EnvironmentObject var session: FocusSession

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("本次总结").font(.headline)
                row("时长", timeString(session.elapsed))
                row("平均分", session.averageScore.map { "\(Int($0))" } ?? "--")
                row("专注占比", session.focusedRatio.map { "\(Int($0 * 100))%" } ?? "--")
                row("记录点", "\(session.samples.count)")
                Button("完成") { session.reset() }
                    .buttonStyle(.borderedProminent).tint(.mint)
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }
            .font(.footnote)
    }
}

func timeString(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%02d:%02d", s / 60, s % 60)
}
