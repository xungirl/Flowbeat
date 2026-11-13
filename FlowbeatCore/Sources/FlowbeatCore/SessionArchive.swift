import Foundation

/// iPhone 端的存档目录：收到手表传来的 JSON 就拷进来，列表页从这里读。
/// 只用 Foundation，所以能在 macOS 上用临时目录测试。
public struct SessionArchive {
    public struct Entry: Identifiable {
        public var id: URL { url }
        public let url: URL
        public let record: SessionRecord
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// 把收到的文件拷进存档目录。WatchConnectivity 给的临时文件在回调返回后就会被删，必须同步拷走。
    /// 同名文件覆盖（同一次专注重复传输不会出现两条）。
    @discardableResult
    public func importFile(at source: URL, name: String? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // 只取文件名部分，防止 metadata 里带 ../ 写到目录外面
        let safeName = URL(fileURLWithPath: name ?? source.lastPathComponent).lastPathComponent
        let dest = directory.appendingPathComponent(safeName.hasSuffix(".json") ? safeName : safeName + ".json")
        // 先确认是能解析的存档，坏文件不收
        _ = try FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: Data(contentsOf: source))
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
        return dest
    }

    /// 读出所有存档，最新的在前；解析失败的文件跳过
    public func loadAll() -> [Entry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let entries: [Entry] = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let r = try? FlowbeatJSON.sessionDecoder.decode(SessionRecord.self, from: data) else { return nil }
            return Entry(url: url, record: r)
        }
        return entries.sorted { ($0.record.samples.first?.t ?? .distantPast) > ($1.record.samples.first?.t ?? .distantPast) }
    }
}
