import SwiftUI
import WidgetKit
import FlowbeatCore

/// 表盘复杂功能 + 智能叠放：今天专注了多少分钟、离每日目标还差多少。点一下打开 Flowbeat（小组件的默认行为）。
///
/// 时间线：现在一条 + 下一个午夜一条（今天归零），policy = .atEnd 让系统午夜后再来要。
/// 专注结束、改了每日目标时，手表 app 会 WidgetCenter.reloadAllTimelines()，所以不用定时刷新、不耗电。
struct FocusProvider: TimelineProvider {
    func placeholder(in context: Context) -> FocusWidgetEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (FocusWidgetEntry) -> Void) {
        // 表盘编辑器里的预览：还没有数据时用示例数字，看起来更像真的
        if context.isPreview && SnapshotFile.read() == nil { return completion(.placeholder) }
        completion(entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FocusWidgetEntry>) -> Void) {
        let snapshot = SnapshotFile.read() ?? .empty()
        let entries = WidgetSnapshot.timelineDates(now: Date(), calendar: .current).map {
            FocusWidgetEntry(date: $0, summary: snapshot.summary(at: $0, calendar: .current))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func entry(at date: Date) -> FocusWidgetEntry {
        let snapshot = SnapshotFile.read() ?? .empty()
        return FocusWidgetEntry(date: date, summary: snapshot.summary(at: date, calendar: .current))
    }
}

struct FocusTodayWidget: Widget {
    static let kind = "FocusToday"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: FocusProvider()) { entry in
            FocusEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Focus today")
        .description("Focused minutes today and progress toward your daily goal.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

private struct FocusEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FocusWidgetEntry
    var body: some View { FocusWidgetView(entry: entry, family: family) }
}

@main
struct FlowbeatWidgetBundle: WidgetBundle {
    var body: some Widget { FocusTodayWidget() }
}
