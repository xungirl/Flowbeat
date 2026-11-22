import Charts
import FlowbeatCore
import FlowbeatPhoneData
import FlowbeatPhoneUI
import SwiftData
import SwiftUI

/// 首页「今天」：今天的专注分钟 vs 每日目标、连续达标天数、最近 7 天 / 30 天、最佳时段、累计。
struct OverviewView: View {
    @Query(sort: \StoredSession.start, order: .reverse) private var sessions: [StoredSession]
    @AppStorage("goal.dailyMinutes") private var dailyGoal = FocusHistory.defaultDailyGoalMinutes
    @EnvironmentObject private var watch: WatchLink

    var body: some View {
        NavigationStack {
            ScrollView {
                let o = PhoneOverview.make(sessions, now: Date(), calendar: .current, dailyGoalMinutes: dailyGoal)
                VStack(spacing: 16) {
                    TodayCard(history: o.history)
                    if sessions.isEmpty {
                        EmptyStateCard()
                    } else {
                        WeekCard(history: o.history)
                        MonthCard(month: o.month, goal: dailyGoal)
                        InsightsCard(overview: o)
                    }
                    Label(watch.status.text, systemImage: watch.status.symbol)
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
        }
    }
}

/// 卡片底色
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TodayCard: View {
    let history: HistorySummary

    var body: some View {
        Card {
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(Color.mint.opacity(0.18), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: history.todayProgress)
                        .stroke(LinearGradient(colors: [.mint, .cyan], startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(history.todayMinutes)").font(.system(.title, design: .rounded).bold()).monospacedDigit()
                        Text("min").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 104, height: 104)
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Focused today").font(.headline)
                    Text("Goal \(history.dailyGoalMinutes) min")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if history.todayGoalMet {
                        Label("Goal reached", systemImage: "checkmark.seal.fill").foregroundStyle(.mint)
                            .font(.subheadline.weight(.semibold))
                    }
                    Label("\(history.streak)-day streak", systemImage: "flame.fill")
                        .font(.subheadline).foregroundStyle(history.streak > 0 ? .orange : .secondary)
                }
            }
        }
    }
}

private struct WeekCard: View {
    let history: HistorySummary

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Last 7 days").font(.headline)
                Chart {
                    ForEach(history.week) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Minutes", d.focusedMinutes))
                            .foregroundStyle(d.focusedMinutes >= history.dailyGoalMinutes ? Color.mint : Color.mint.opacity(0.45))
                            .cornerRadius(4)
                    }
                    RuleMark(y: .value("Goal", history.dailyGoalMinutes))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .frame(height: 150)
            }
        }
    }
}

private struct MonthCard: View {
    let month: [DayTotal]
    let goal: Int

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Last 30 days").font(.headline)
                    Spacer()
                    Text("\(month.filter { $0.focusedMinutes >= goal }.count) days at goal")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Chart(month) { d in
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Minutes", d.focusedMinutes))
                        .foregroundStyle(d.focusedMinutes >= goal ? Color.mint : Color.mint.opacity(0.45))
                        .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 140)
            }
        }
    }
}

private struct InsightsCard: View {
    let overview: PhoneOverview

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Insights").font(.headline)
                if let best = overview.history.bestHour {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sun.max.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your best time: \(Self.hourRange(best.hour))").font(.subheadline.weight(.semibold))
                            Text("\(Int((best.focusedRatio * 100).rounded()))% of scored time was focused")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                    stat("Sessions", "\(overview.totalSessions)")
                    stat("Focused in total", Self.hoursText(overview.totalFocusedMinutes))
                    stat("Per active day", overview.activeDayAverageMinutes.map { "\($0) min" } ?? "—")
                    stat("Your labels", "\(overview.focusedLabels) / \(overview.distractedLabels)")
                }
                Text("Labels: Focused / Distracted taps on the watch.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }

    static func hourRange(_ hour: Int) -> String {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        guard let a = cal.date(byAdding: .hour, value: hour, to: base),
              let b = cal.date(byAdding: .hour, value: hour + 1, to: base) else { return "\(hour):00" }
        return (a..<b).formatted(.interval.hour())
    }

    static func hoursText(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min"
            : Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

private struct EmptyStateCard: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("No focus sessions yet", systemImage: "applewatch").font(.headline)
                Text("Start a focus session in Flowbeat on your Apple Watch. When you end it, the session appears here with its focus timeline.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let sample = SampleSession.record {
                    NavigationLink {
                        ScrollView { SessionDetailContent(record: sample, isSample: true).padding() }
                            .navigationTitle("Sample session")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("View a sample session", systemImage: "chart.xyaxis.line")
                    }
                    .buttonStyle(.bordered)
                    .tint(.mint)
                }
            }
        }
    }
}
