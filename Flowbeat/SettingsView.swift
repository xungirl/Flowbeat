import SwiftUI
import FlowbeatCore

/// 设置页（开始页右上角齿轮）。改动在下一次开始专注时生效。
struct SettingsView: View {
    @AppStorage(AppSettings.Key.nudgeEnabled) private var nudgeEnabled = true
    @AppStorage(AppSettings.Key.nudgeMinutes) private var nudgeMinutes = NudgeSettings.defaultDistractedMinutes
    @AppStorage(AppSettings.Key.nudgeCooldown) private var nudgeCooldown = NudgeSettings.defaultCooldownMinutes

    var body: some View {
        List {
            Section {
                Toggle("Distraction nudge", isOn: $nudgeEnabled)
                if nudgeEnabled {
                    Stepper(value: $nudgeMinutes, in: NudgeSettings.distractedMinutesRange) {
                        settingRow("After", minutes: nudgeMinutes)
                    }
                    Stepper(value: $nudgeCooldown, in: NudgeSettings.cooldownMinutesRange) {
                        settingRow("At most every", minutes: nudgeCooldown)
                    }
                }
            } footer: {
                Text("A gentle tap on your wrist when you have been distracted for a while. Never while you walk, calibrate or take a break.")
            }
        }
        .navigationTitle("Settings")
    }

    private func settingRow(_ title: LocalizedStringKey, minutes: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text("\(minutes) min").monospacedDigit()
        }
    }
}
