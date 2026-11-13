import Charts
import FlowbeatCore
import SwiftUI

// iPhone 端的视图。只用 iOS 和 macOS 都有的 SwiftUI / Charts API，
// 所以 macOS 上也能编译，能用 ImageRenderer 渲染成 PNG（见 render-snapshots）。
// List / NavigationStack 这类系统容器放在 iOS app 里（ImageRenderer 渲染不了它们）。

/// 和手表一样的配色：≥70 心流（薄荷绿），40–70 分心（黄），<40 走神（橙红）
public enum PhoneTheme {
    public static func color(for score: Double?) -> Color {
        guard let s = score else { return .gray }
        if s >= 70 { return .mint }
        if s >= 40 { return .yellow }
        return .orange
    }

    public static func color(forState state: String) -> Color {
        switch state {
        case "focused": return .mint
        case "distracted": return .orange
        case "away": return .cyan
        default: return .gray
        }
    }

    public static func stateText(_ state: String) -> String {
        switch state {
        case "focused": return "专注"
        case "distracted": return "走神"
        case "away": return "离座"
        default: return "不确定"
        }
    }
}

func durationText(_ minutes: Double) -> String {
    let s = Int(minutes * 60)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - 专注曲线

/// 专注分曲线 + 离座区间 + 你的标签 + AI 判断
public struct ScoreTimelineChart: View {
    let timeline: SessionTimeline

    public init(timeline: SessionTimeline) { self.timeline = timeline }

    public var body: some View {
        Chart {
            ForEach(timeline.awaySpans) { span in
                RectangleMark(xStart: .value("开始", span.start), xEnd: .value("结束", span.end),
                              yStart: .value("下", 0), yEnd: .value("上", 100))
                    .foregroundStyle(.cyan.opacity(0.15))
            }
            RuleMark(y: .value("心流线", 70))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.mint.opacity(0.6))
            ForEach(timeline.scores) { p in
                LineMark(x: .value("分钟", p.minute), y: .value("专注分", p.score), series: .value("段", p.segment))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    // 渐变按 y 方向铺满绘图区：高分段是薄荷绿，低分段是橙色，和手表圆环配色一致
                    .foregroundStyle(LinearGradient(colors: [.orange, .yellow, .mint], startPoint: .bottom, endPoint: .top))
            }
            ForEach(timeline.labels) { l in
                RuleMark(x: .value("标签", l.minute))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(l.label == "focused" ? Color.mint : .orange)
                    .annotation(position: .top, spacing: 2) {
                        Image(systemName: l.label == "focused" ? "brain.head.profile" : "cloud.fog.fill")
                            .font(.caption2)
                            .foregroundStyle(l.label == "focused" ? Color.mint : .orange)
                    }
            }
            ForEach(timeline.judgments) { j in
                PointMark(x: .value("分钟", j.minute), y: .value("AI 分", j.judgment.score))
                    .symbol(.diamond)
                    .symbolSize(70)
                    .foregroundStyle(PhoneTheme.color(forState: j.judgment.state))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: 0...max(1, timeline.durationMinutes))
        .chartXAxisLabel("分钟")
        .chartYAxis {
            AxisMarks(values: [0, 40, 70, 100])
        }
    }
}

/// 图例：线 = 手表规则分，◆ = AI 判断，竖线 = 你的标签，青色块 = 离座
public struct TimelineLegend: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 12) {
            item(Capsule().fill(Color.mint).frame(width: 12, height: 3), "规则分")
            item(Image(systemName: "diamond.fill").foregroundStyle(.mint), "AI 判断")
            item(Rectangle().fill(Color.orange).frame(width: 2, height: 11), "你的标签")
            item(Rectangle().fill(Color.cyan.opacity(0.3)).frame(width: 10, height: 10), "离座")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func item<I: View>(_ icon: I, _ text: String) -> some View {
        HStack(spacing: 3) { icon; Text(text) }
    }
}

// MARK: - 汇总

public struct SessionSummaryHeader: View {
    let timeline: SessionTimeline

    public init(timeline: SessionTimeline) { self.timeline = timeline }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(timeline.averageScore.map { "\(Int($0))" } ?? "--")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(PhoneTheme.color(for: timeline.averageScore))
                Text("平均专注").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            stat("时长", durationText(timeline.durationMinutes))
            stat("心流占比", timeline.focusedRatio.map { "\(Int($0 * 100))%" } ?? "--")
            stat("离座", "\(timeline.awayCount) 次")
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(v).font(.system(.headline, design: .rounded)).monospacedDigit()
            Text(k).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

public struct JudgmentRows: View {
    let timeline: SessionTimeline

    public init(timeline: SessionTimeline) { self.timeline = timeline }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(timeline.judgments) { j in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(durationText(j.minute)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text(PhoneTheme.stateText(j.judgment.state))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(PhoneTheme.color(forState: j.judgment.state).opacity(0.2), in: Capsule())
                    Text(j.judgment.reason).font(.subheadline).lineLimit(2)
                    Spacer(minLength: 0)
                    if j.judgment.source == "fallback" {
                        Text("兜底").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - 详情页内容

public struct SessionDetailContent: View {
    let record: SessionRecord
    let timeline: SessionTimeline
    let isSample: Bool

    public init(record: SessionRecord, isSample: Bool = false) {
        self.record = record
        self.timeline = SessionTimeline(record: record)
        self.isSample = isSample
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isSample {
                Label("示例数据：手表模拟器演示模式（模拟传感器）生成", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SessionSummaryHeader(timeline: timeline)
            card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("专注曲线").font(.headline)
                    ScoreTimelineChart(timeline: timeline).frame(height: 220)
                    TimelineLegend()
                }
            }
            if !timeline.judgments.isEmpty {
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI 判断（每个窗口）").font(.headline)
                        JudgmentRows(timeline: timeline)
                    }
                }
            }
            if let r = record.review {
                card {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("AI 复盘", systemImage: "sparkles").font(.headline).foregroundStyle(.mint)
                        Text(r.summary).font(.subheadline)
                        Label(r.tip, systemImage: "lightbulb.fill").font(.subheadline)
                    }
                }
            }
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// 列表里的一行
public struct SessionRow: View {
    let timeline: SessionTimeline
    let isSample: Bool

    public init(record: SessionRecord, isSample: Bool = false) {
        self.timeline = SessionTimeline(record: record)
        self.isSample = isSample
    }

    public var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.gray.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: (timeline.averageScore ?? 0) / 100)
                    .stroke(PhoneTheme.color(for: timeline.averageScore), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(timeline.averageScore.map { "\(Int($0))" } ?? "--").font(.caption.bold()).monospacedDigit()
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(timeline.start.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    .font(.subheadline.weight(.medium))
                Text("\(durationText(timeline.durationMinutes)) · 离座 \(timeline.awayCount) 次" + (isSample ? " · 示例" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
