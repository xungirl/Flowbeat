import Foundation

/// 手表 → iPhone 的存档同步账本：哪些存档 iPhone 已经确认收到了。
///
/// 以前只在专注结束时发一次，发失败（手机没电、蓝牙断了、iPhone app 还没装）就再也不发。
/// 现在每次 WatchConnectivity 激活、每次专注结束，都把「存档目录里有、账本里没有、也没在传」的文件补发一遍；
/// `didFinish` 没有错误才记进账本。这样：
/// - 先用手表、过几周才装 iPhone app，以前的记录也会全部补传过去；
/// - iPhone 上删掉的记录不会被重新传回来（账本里已经有了）。
///
/// 纯逻辑，只用 Foundation，测试里喂假的文件名列表。
public struct SyncLedger: Equatable, Sendable {
    public private(set) var delivered: Set<String>

    public init(delivered: Set<String> = []) {
        self.delivered = delivered
    }

    /// 还要发的：存档里有、没送达过、也不在传输中。按名字排序（名字是开始时间，旧的先发）
    public func pending(archive: [String], inFlight: Set<String>) -> [String] {
        archive.filter { !delivered.contains($0) && !inFlight.contains($0) }.sorted()
    }

    public mutating func markDelivered(_ name: String) {
        delivered.insert(name)
    }

    /// 存档已经删掉的名字不用再记（账本不会无限长）
    public mutating func prune(keeping archive: [String]) {
        delivered.formIntersection(archive)
    }

    // MARK: - 存取（UserDefaults 里存一个字符串数组）

    public static let defaultsKey = "sync.deliveredSessions"

    public static func load(from defaults: UserDefaults) -> SyncLedger {
        SyncLedger(delivered: Set(defaults.stringArray(forKey: defaultsKey) ?? []))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(delivered.sorted(), forKey: Self.defaultsKey)
    }
}

/// 手表和 iPhone 之间通过 `updateApplicationContext` 同步的设置：每日目标。
/// 两边谁后改听谁的（带修改时间），收到旧的就忽略。
public struct SharedSettings: Equatable, Sendable {
    public var dailyGoalMinutes: Int
    public var updatedAt: Date

    public init(dailyGoalMinutes: Int, updatedAt: Date) {
        self.dailyGoalMinutes = dailyGoalMinutes.clamped(to: FocusHistory.dailyGoalRange)
        self.updatedAt = updatedAt
    }

    static let goalKey = "dailyGoalMinutes"
    static let timeKey = "settingsUpdatedAt"

    public var context: [String: Any] {
        [Self.goalKey: dailyGoalMinutes, Self.timeKey: updatedAt.timeIntervalSince1970]
    }

    public init?(context: [String: Any]) {
        guard let goal = context[Self.goalKey] as? Int, let t = context[Self.timeKey] as? Double else { return nil }
        self.init(dailyGoalMinutes: goal, updatedAt: Date(timeIntervalSince1970: t))
    }

    /// 收到对方的设置后要不要采用：比本地的新才采用
    public func shouldReplace(_ local: SharedSettings?) -> Bool {
        guard let local else { return true }
        return updatedAt > local.updatedAt
    }

    // 本地存取
    static let localGoalKey = "goal.dailyMinutes"   // 和手表 HistoryStore.dailyGoalKey 同一个键
    static let localTimeKey = "goal.updatedAt"

    public static func load(from d: UserDefaults) -> SharedSettings? {
        guard d.object(forKey: localGoalKey) != nil else { return nil }
        return SharedSettings(dailyGoalMinutes: d.integer(forKey: localGoalKey),
                              updatedAt: Date(timeIntervalSince1970: d.double(forKey: localTimeKey)))
    }

    public func save(to d: UserDefaults) {
        d.set(dailyGoalMinutes, forKey: Self.localGoalKey)
        d.set(updatedAt.timeIntervalSince1970, forKey: Self.localTimeKey)
    }
}
