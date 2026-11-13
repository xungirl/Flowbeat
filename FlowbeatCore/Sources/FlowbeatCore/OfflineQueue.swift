import Foundation

// 离线容忍：连不上后端时，把 2 分钟窗口摘要先排队，按指数退避重试，队列有上限。
//
// 设计取舍：
// - 退避是「整个队列」的，不是每条各自退避。后端挂了，所有请求都会失败；
//   每条各自计时会在恢复前把整条队列挨个试一遍，白白耗电。
// - 严格按先后顺序发（队头阻塞）：结果要按时间顺序进存档和复盘。
// - 4xx（除 408/429）是永久错误（比如数据被后端校验拒绝），重试也没用，直接丢掉这一条，不阻塞后面的。
// - 不做随机抖动（jitter）：只有一块手表连一个后端，不存在成千上万客户端同时重试的「惊群」。
// - 只在内存里：一次专注内有效。app 被杀掉时没发出去的窗口就丢了，但窗口本身在 SessionRecord.windows 里。

/// 退避策略：第 n 次连续失败后等待 base × multiplier^(n-1)，封顶 maxDelay。
public struct RetryPolicy: Codable, Equatable, Sendable {
    public var baseDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    /// 同一条最多试几次，之后丢弃（防止一条怪数据永远堵住队头）
    public var maxAttempts: Int

    public init(baseDelay: TimeInterval = 15, multiplier: Double = 2, maxDelay: TimeInterval = 300, maxAttempts: Int = 8) {
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    public func delay(afterFailures n: Int) -> TimeInterval {
        guard n > 0 else { return 0 }
        return min(maxDelay, baseDelay * pow(multiplier, Double(n - 1)))
    }
}

/// 有上限的先进先出队列 + 队列级退避。纯值类型，好测。
public struct OfflineQueue<Item: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let id: Int
        public let item: Item
        public let enqueuedAt: Date
        public internal(set) var attempts: Int
    }

    public let capacity: Int
    public let maxAge: TimeInterval
    public let policy: RetryPolicy
    public private(set) var entries: [Entry] = []
    public private(set) var consecutiveFailures = 0
    public private(set) var nextAttemptAt: Date?
    /// 因为队列满、过期、永久错误、超过最大次数而丢掉的条数
    public private(set) var droppedCount = 0
    private var nextID = 0

    public init(capacity: Int = 30, maxAge: TimeInterval = 3600, policy: RetryPolicy = RetryPolicy()) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.maxAge = maxAge
        self.policy = policy
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var head: Entry? { entries.first }

    /// 还在退避期内吗（退避期内不发请求，省电）
    public func isBlocked(at now: Date) -> Bool {
        nextAttemptAt.map { now < $0 } ?? false
    }

    /// 入队；满了就丢最老的一条。返回被挤掉的条目。
    @discardableResult
    public mutating func enqueue(_ item: Item, at now: Date) -> [Item] {
        let entry = Entry(id: nextID, item: item, enqueuedAt: now, attempts: 0)
        entries.append(entry)
        nextID += 1
        var dropped: [Item] = []
        while entries.count > capacity {
            dropped.append(entries.removeFirst().item)
        }
        droppedCount += dropped.count
        return dropped
    }

    /// 丢掉排队太久的（比如超过 1 小时，判断已经没意义了）
    @discardableResult
    public mutating func expire(at now: Date) -> Int {
        let before = entries.count
        let maxAge = self.maxAge   // 闭包里不能再读 self（removeAll 正在独占修改 entries）
        entries.removeAll { now.timeIntervalSince($0.enqueuedAt) > maxAge }
        let n = before - entries.count
        droppedCount += n
        return n
    }

    /// 发送成功：移除这一条，清空退避
    public mutating func recordSuccess(id: Int) {
        entries.removeAll { $0.id == id }
        consecutiveFailures = 0
        nextAttemptAt = nil
    }

    /// 临时失败（连不上、超时、5xx）：这一条次数 +1，整个队列进入退避。返回这一条是否还留在队列里。
    @discardableResult
    public mutating func recordTransientFailure(id: Int, at now: Date) -> Bool {
        consecutiveFailures += 1
        nextAttemptAt = now.addingTimeInterval(policy.delay(afterFailures: consecutiveFailures))
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[i].attempts += 1
        if entries[i].attempts >= policy.maxAttempts {
            entries.remove(at: i)
            droppedCount += 1
            return false
        }
        return true
    }

    /// 永久失败（后端说数据不对）：丢掉这一条，不影响退避
    public mutating func recordPermanentFailure(id: Int) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        droppedCount += before - entries.count
    }
}

/// 后端返回了非 200。4xx 里除了 408（超时）、429（限流）都算永久错误。
public struct HTTPStatusError: Error, Equatable {
    public let code: Int
    public init(code: Int) { self.code = code }
    public var isPermanent: Bool { (400..<500).contains(code) && code != 408 && code != 429 }
}

/// 一次 flush 的结果
public struct SyncResult: Sendable {
    /// 按发送顺序（= 窗口时间顺序）送达的请求和判断
    public var delivered: [(request: JudgeRequest, judgment: Judgment)] = []
    public var droppedPermanent = 0
    public var pending = 0
    public var lastError: String?
}

/// 手表上的「判断发送器」：所有判断请求都先进队列再 flush，在线时等于直接发，离线时自动排队重试。
/// actor 保证 flush 不会被并发执行两次（同一条不会发两遍）。
public actor JudgeSync {
    public typealias Send = @Sendable (JudgeRequest) async throws -> Judgment

    public private(set) var queue: OfflineQueue<JudgeRequest>
    private let send: Send
    private let now: @Sendable () -> Date
    private var isFlushing = false

    public init(queue: OfflineQueue<JudgeRequest> = OfflineQueue(), now: @escaping @Sendable () -> Date = { Date() },
                send: @escaping Send) {
        self.queue = queue
        self.now = now
        self.send = send
    }

    public var pendingCount: Int { queue.count }

    /// 新窗口：入队后立刻尝试 flush（退避期内则只入队）
    public func submit(_ request: JudgeRequest) async -> SyncResult {
        queue.enqueue(request, at: now())
        return await flush()
    }

    /// 按顺序发送队列里的请求，遇到临时失败就停（后端还没恢复，别继续试）。
    /// - Parameter ignoringBackoff: 结束专注时最后试一次，不等退避
    public func flush(ignoringBackoff: Bool = false) async -> SyncResult {
        var result = SyncResult()
        // 已经有一个 flush 在跑：它的循环会把新入队的也发掉
        guard !isFlushing else {
            result.pending = queue.count
            return result
        }
        isFlushing = true
        defer { isFlushing = false }

        queue.expire(at: now())
        while let head = queue.head, ignoringBackoff || !queue.isBlocked(at: now()) {
            do {
                let j = try await send(head.item)
                queue.recordSuccess(id: head.id)
                result.delivered.append((head.item, j))
            } catch let e as HTTPStatusError where e.isPermanent {
                queue.recordPermanentFailure(id: head.id)
                result.droppedPermanent += 1
                result.lastError = "HTTP \(e.code)"
            } catch {
                queue.recordTransientFailure(id: head.id, at: now())
                result.lastError = String(describing: error)
                break
            }
        }
        result.pending = queue.count
        return result
    }
}
