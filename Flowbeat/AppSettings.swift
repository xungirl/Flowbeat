import Foundation
import WatchKit
import FlowbeatCore

/// 用户设置（UserDefaults 的键 + 默认值）。设置页用 @AppStorage 读写同样的键，
/// FocusSession 在每次开始专注时读一次（专注进行中改设置，下一次生效）。
enum AppSettings {
    enum Key {
        static let nudgeEnabled = "nudge.enabled"
        static let nudgeMinutes = "nudge.distractedMinutes"
        static let nudgeCooldown = "nudge.cooldownMinutes"
    }

    private static var defaults: UserDefaults { .standard }

    /// 没设置过的键返回默认值（UserDefaults.integer 对不存在的键返回 0，不能直接用）
    private static func int(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    static var nudge: NudgeSettings {
        NudgeSettings(enabled: bool(Key.nudgeEnabled, true),
                      distractedMinutes: int(Key.nudgeMinutes, NudgeSettings.defaultDistractedMinutes),
                      cooldownMinutes: int(Key.nudgeCooldown, NudgeSettings.defaultCooldownMinutes))
    }
}

/// 所有触感反馈集中在这里，方便统一调整「轻重」
enum Haptics {
    /// 走神提醒：选最轻的「向上」两下，而不是 .notification（像来消息，太重、会让人以为有通知）
    static func nudge() { WKInterfaceDevice.current().play(.directionUp) }
    static func label() { WKInterfaceDevice.current().play(.click) }
}
