import Foundation
import FlowbeatCore

/// App Group 共享容器里的 widget-snapshot.json。手表 app 写、小组件读（这个文件两个 target 都编译）。
///
/// 没有 App Group（未签名的模拟器构建、还没注册 Team ID）时 containerURL 是 nil：
/// app 不写，小组件显示 0 分钟——不会崩，只是没数据。
enum SnapshotFile {
    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent(WidgetSnapshot.fileName)
    }

    static func read() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return WidgetSnapshot.decode(data)
    }

    @discardableResult
    static func write(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url, let data = try? snapshot.encoded() else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
