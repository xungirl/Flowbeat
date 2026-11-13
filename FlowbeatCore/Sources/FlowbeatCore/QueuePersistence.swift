import Foundation

// 离线队列落盘：app 被杀掉 / 结束专注时还没发出去的窗口，下次启动还在。
//
// 设计：
// - 一次专注一个文件：Application Support/Flowbeat/judge-queue/<session>.json，<session> 和
//   Documents/sessions/<session>.json 存档同名。这样晚到的判断知道该补进哪个存档，
//   当前专注和「上次剩下的」也不会抢同一个文件。
// - 每次队列变化（入队、送达、失败、过期）都整份重写，原子写（先写临时文件再改名），
//   写到一半断电也不会留下半个 JSON。队列最多 30 条，每条是一个 2 分钟窗口摘要，整份只有几十 KB。
// - 读回来时按「现在代码里的」上限重新整理：超过 1 小时的丢掉、超过 30 条丢最老的。
//   文件里存的旧上限不算数，以后改上限也不会被旧文件带偏。
// - 坏文件（解析失败）改名成 .corrupt 放一边，不让它每次启动都失败，也不直接删掉，方便排查。
// 只在 AI build 里有意义（Release 没有队列），但逻辑在 Core 里，单元测试覆盖（QueuePersistenceTests）。

// OfflineQueue.restoring(...) 在 OfflineQueue.swift 里（要改 private(set) 的属性）。

/// 一个 Codable 值存成一个 JSON 文件，原子写。
public struct JSONFileStore<Value: Codable> {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 没有文件 → nil；文件坏了 → 改名成 .corrupt 放一边，返回 nil
    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try Self.decoder.decode(Value.self, from: data)
        } catch {
            let aside = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    /// 原子写：Data.write(.atomic) 先写临时文件再 rename
    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// 手表上所有专注的待发队列，一次专注一个文件。
public struct JudgeQueueStore: Sendable {
    public let directory: URL
    public let capacity: Int
    public let maxAge: TimeInterval

    public init(directory: URL, capacity: Int = 30, maxAge: TimeInterval = 3600) {
        self.directory = directory
        self.capacity = capacity
        self.maxAge = maxAge
    }

    /// Application Support/Flowbeat/judge-queue（不在 Documents：这是内部状态，不是用户文件）
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Flowbeat", isDirectory: true)
            .appendingPathComponent("judge-queue", isDirectory: true)
    }

    private func store(_ session: String) -> JSONFileStore<OfflineQueue<JudgeRequest>> {
        // 只取文件名部分，防止 session 名里带 ../
        let safe = URL(fileURLWithPath: session).lastPathComponent
        return JSONFileStore(url: directory.appendingPathComponent(safe + ".json"))
    }

    /// 存一份；队列空了就删文件（没有待发的就不留文件）
    public func save(_ queue: OfflineQueue<JudgeRequest>, session: String) throws {
        if queue.isEmpty {
            store(session).remove()
        } else {
            try store(session).save(queue)
        }
    }

    /// 读回来并按现在的上限整理；整理完是空的就删文件
    public func load(session: String, at now: Date = Date()) -> OfflineQueue<JudgeRequest>? {
        guard let saved = store(session).load() else { return nil }
        let q = OfflineQueue.restoring(saved, capacity: capacity, maxAge: maxAge, at: now)
        if q.isEmpty { store(session).remove(); return nil }
        return q
    }

    public func remove(session: String) {
        store(session).remove()
    }

    /// 有待发队列的专注（文件名去掉 .json），旧的在前
    public func sessions() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}

extension SessionRecord {
    /// 窗口本身在专注进行时就记进了 windows，这里只补判断和时间轴。
    /// 专注结束后才送达的判断（上次离线没发出去，这次启动补发成功）补进存档。
    /// 时间轴上放在窗口所在的分钟；结束秒数已经不知道了（那是上次运行时内存里的），留空。
    public func appendingLateJudgments(_ delivered: [(request: JudgeRequest, judgment: Judgment)]) -> SessionRecord {
        SessionRecord(samples: samples, windows: windows,
                      judgments: judgments + delivered.map(\.judgment), review: review,
                      timeline: (timeline ?? []) + delivered.map {
                          JudgedWindow(minute: $0.request.window.minuteOfSession, judgment: $0.judgment)
                      },
                      plan: plan)
    }
}
