import Foundation

// 首次启动说明 + 权限状态。纯逻辑，UI 在 Flowbeat/OnboardingView.swift。
//
// 顺序是「先讲清楚，再要权限」：说明页（做什么 / 不是医疗设备 / 数据只在手表上）看完，
// 用户点「继续」才弹 HealthKit 和「运动与健身」的系统授权窗。
// 被拒绝时不是死胡同：开始页显示原因和去哪里打开，并且可以「再检查一次」。

/// 存一个整数的地方（app 里是 UserDefaults.standard，测试里是假的）
public protocol IntegerStore: AnyObject {
    func integer(forKey key: String) -> Int
    func set(_ value: Int, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: IntegerStore {}

/// 首次启动说明有没有看过。带版本号：以后说明内容有实质变化（比如上线 AI、数据要出手表），
/// 把 currentVersion 加 1，所有人会再看一次。
public struct OnboardingState {
    public static let currentVersion = 1
    public static let key = "onboarding.completedVersion"

    private let store: IntegerStore
    private let version: Int

    public init(store: IntegerStore, version: Int = OnboardingState.currentVersion) {
        self.store = store
        self.version = version
    }

    public var needsOnboarding: Bool {
        store.integer(forKey: Self.key) < version
    }

    public func complete() {
        store.set(version, forKey: Self.key)
    }

    public func reset() {
        store.removeObject(forKey: Self.key)
    }
}

/// 一个系统权限的状态（HealthKit 和 CoreMotion 各有各的枚举，统一成这一个）
public enum PermissionStatus: String, Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    /// 设备不支持（比如没有 HealthKit 的设备）
    case unavailable
}

/// 现在能不能开始专注，以及要给用户看哪些提示
public struct StartReadiness: Equatable, Sendable {
    public enum Notice: Equatable, Sendable {
        /// 设备不支持「健康」：没法开始
        case healthUnavailable
        /// 心率 / 体能训练权限被拒：没法开始，告诉用户去哪里打开
        case healthDenied
        /// 还没问过：点开始时会弹授权窗
        case healthNotAsked
        /// 运动与健身被拒：可以开始，但走动不会自动暂停
        case motionDenied
    }

    public let canStart: Bool
    public let notices: [Notice]

    public static func evaluate(health: PermissionStatus, motion: PermissionStatus) -> StartReadiness {
        var notices: [Notice] = []
        let canStart: Bool
        switch health {
        case .granted:
            canStart = true
        case .notDetermined:
            canStart = true           // 开始时会请求授权
            notices.append(.healthNotAsked)
        case .denied:
            canStart = false          // 没有心率就没有专注估计，也开不了 workout（后台会被挂起）
            notices.append(.healthDenied)
        case .unavailable:
            canStart = false
            notices.append(.healthUnavailable)
        }
        // 手腕加速度（CMDeviceMotion）不需要授权；被拒的只是活动识别和计步 → 离座检测关闭
        if motion == .denied { notices.append(.motionDenied) }
        return StartReadiness(canStart: canStart, notices: notices)
    }
}
