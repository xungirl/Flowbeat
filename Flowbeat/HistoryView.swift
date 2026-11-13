import SwiftUI
import Charts
import FlowbeatCore

/// 历史页：今天 / 每日目标、连续达标天数、最近 7 天柱状图、一天里最专注的时段。
struct HistoryView: View {
    @ObservedObject var history = HistoryStore.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let s = history.summary {
                    VStack(spacing: 10) {
                        todayCard(s)
                        weekChart(s)
                        bestHourCard(s).id("bottom")
                    }
                } else {
                    ProgressView()
                }
            }
            // 模拟器截图：-scrollBottom 数据出来后滚到底（看柱状图和最佳时段）
            .task(id: history.summary) {
                guard StartView.argument("-scrollBottom"), history.summary != nil else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .navigationTitle("History")
        .containerBackground(Color.mint.gradient.opacity(0.18), for: .navigation)
        .onAppear { history.refresh() }
    }

    private func todayCard(_ s: HistorySummary) -> some View {
        HStack(spacing: 10) {
            Ring(progress: s.todayProgress, colors: s.todayGoalMet ? Theme.flow : [.yellow, .orange], lineWidth: 6) {
                VStack(spacing: -2) {
                    Text(verbatim: "\(s.todayMinutes)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("min").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Today").font(.system(.footnote, weight: .semibold))
                Text("Goal \(s.dailyGoalMinutes) min").font(.caption2).foregroundStyle(.secondary)
                Label {
                    Text("\(s.streak)-day streak")
                } icon: {
                    Image(systemName: "flame.fill").foregroundStyle(s.streak > 0 ? .orange : .secondary)
                }
                .font(.caption2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func weekChart(_ s: HistorySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 7 days").font(.system(.footnote, weight: .semibold))
            Chart {
                ForEach(s.week) { d in
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Minutes", d.focusedMinutes))
                        .foregroundStyle(d.focusedMinutes >= s.dailyGoalMinutes ? Color.mint : Color.mint.opacity(0.45))
                        .cornerRadius(2)
                }
                RuleMark(y: .value("Goal", s.dailyGoalMinutes))
                    .foregroundStyle(.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 90)
            .accessibilityLabel(Text("Focused minutes, last 7 days"))
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func bestHourCard(_ s: HistorySummary) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sun.max.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("Best time of day").font(.system(.footnote, weight: .semibold))
                if let b = s.bestHour {
                    Text(verbatim: Self.hourRange(b.hour))
                        .font(.system(.body, design: .rounded, weight: .semibold))
                    Text("\(Int((b.focusedRatio * 100).rounded()))% in flow").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Needs 10+ scored minutes in one hour").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 「9:00–10:00」，按用户的 12/24 小时制
    static func hourRange(_ hour: Int) -> String {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        guard let a = cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) else { return "\(hour)" }
        let b = a.addingTimeInterval(3600)
        let style = Date.FormatStyle.dateTime.hour().minute()
        return "\(a.formatted(style))–\(b.formatted(style))"
    }
}
