import SwiftUI
import WidgetKit
import FlowbeatCore

/// 小组件显示的数据：今天专注分钟数、每日目标、连续达标天数
struct FocusWidgetEntry: TimelineEntry {
    let date: Date
    let todayMinutes: Int
    let goalMinutes: Int
    let streak: Int

    var progress: Double { goalMinutes > 0 ? min(1, Double(todayMinutes) / Double(goalMinutes)) : 0 }
    var goalMet: Bool { todayMinutes >= goalMinutes }

    init(date: Date, summary: HistorySummary) {
        self.date = date
        todayMinutes = summary.todayMinutes
        goalMinutes = summary.dailyGoalMinutes
        streak = summary.streak
    }

    init(date: Date, todayMinutes: Int, goalMinutes: Int, streak: Int) {
        self.date = date
        self.todayMinutes = todayMinutes
        self.goalMinutes = goalMinutes
        self.streak = streak
    }

    static let placeholder = FocusWidgetEntry(date: Date(), todayMinutes: 42, goalMinutes: 60, streak: 3)
}

/// 四种表盘尺寸的视图。这个文件同时编进小组件扩展和手表 app（模拟器里的预览页用它截图）。
struct FocusWidgetView: View {
    let entry: FocusWidgetEntry
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .accessoryCorner: corner
        default: circular
        }
    }

    /// 圆形：目标进度环 + 中间的分钟数
    private var circular: some View {
        Gauge(value: entry.progress) {
            Image(systemName: "waveform.path.ecg")
        } currentValueLabel: {
            Text(verbatim: "\(entry.todayMinutes)")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(entry.goalMet ? .mint : .cyan)
        .widgetAccentable()
        .accessibilityLabel(Text("Focused today: \(entry.todayMinutes) of \(entry.goalMinutes) min"))
    }

    /// 长方形：标题 + 「42 / 60 分钟」+ 进度条 + 连续天数
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                Text("Focus today")
                Spacer(minLength: 2)
                if entry.streak > 0 {
                    // 连续达标天数：火苗 + 数字
                    Label {
                        Text(verbatim: "\(entry.streak)")
                    } icon: {
                        Image(systemName: "flame.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("\(entry.streak)-day streak"))
                }
            }
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(.mint)
            .widgetAccentable()
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: "\(entry.todayMinutes)")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text("/ \(entry.goalMinutes) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: entry.progress)
                .tint(entry.goalMet ? .mint : .cyan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一行文字（表盘顶部 / 日期旁边）
    private var inline: some View {
        Label {
            Text("Focus \(entry.todayMinutes)/\(entry.goalMinutes) min")
        } icon: {
            Image(systemName: "waveform.path.ecg")
        }
    }

    /// 角落（Infograph 等表盘）：数字 + 弧形进度
    private var corner: some View {
        Text(verbatim: "\(entry.todayMinutes)")
            .font(.system(.title3, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .widgetCurvesContent()
            .widgetLabel {
                Gauge(value: entry.progress) { Text("min") }
                    .tint(entry.goalMet ? .mint : .cyan)
            }
    }
}
