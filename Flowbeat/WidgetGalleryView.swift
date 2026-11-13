#if targetEnvironment(simulator)
import SwiftUI
import WidgetKit
import FlowbeatCore

/// 只在模拟器里编译：把小组件的视图画在手表 app 里，用来截图（-widgetGallery）。
/// 这不是真正的表盘：系统表盘会用自己的着色（vibrant / tinted），尺寸也随表盘不同，所以只用来看排版。
struct WidgetGalleryView: View {
    @ObservedObject var history = HistoryStore.shared

    private var entry: FocusWidgetEntry {
        history.summary.map { FocusWidgetEntry(date: Date(), summary: $0) } ?? .placeholder
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                VStack(spacing: 0) {
                    Text("Watch face widgets").font(.system(.footnote, weight: .semibold))
                    Text("Preview inside the app").font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    FocusWidgetView(entry: entry, family: .accessoryCircular)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(.white.opacity(0.12)))
                    VStack(alignment: .leading) {
                        FocusWidgetView(entry: entry, family: .accessoryInline)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    }
                }
                FocusWidgetView(entry: entry, family: .accessoryRectangular)
                    .padding(8)
                    .frame(width: 176, height: 78)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.12)))
            }
        }
        .containerBackground(Color.black, for: .navigation)
        .onAppear { history.refresh() }
    }
}
#endif
