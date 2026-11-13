import SwiftUI
import FlowbeatCore

/// 设置页（开始页右上角齿轮）。改动在下一次开始专注时生效。
struct SettingsView: View {
    @AppStorage(AppSettings.Key.nudgeEnabled) private var nudgeEnabled = true
    @AppStorage(AppSettings.Key.nudgeMinutes) private var nudgeMinutes = NudgeSettings.defaultDistractedMinutes
    @AppStorage(AppSettings.Key.nudgeCooldown) private var nudgeCooldown = NudgeSettings.defaultCooldownMinutes
    @AppStorage(AppSettings.Key.pomodoroWork) private var pomodoroWork = PomodoroSettings.defaultWorkMinutes
    @AppStorage(AppSettings.Key.pomodoroBreak) private var pomodoroBreak = PomodoroSettings.defaultBreakMinutes
    @AppStorage(AppSettings.Key.sessionGoal) private var sessionGoal = 0
    @AppStorage(HistoryStore.dailyGoalKey) private var dailyGoal = FocusHistory.defaultDailyGoalMinutes

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

            Section("Pomodoro") {
                Stepper(value: $pomodoroWork, in: PomodoroSettings.workMinutesRange, step: 5) {
                    settingRow("Work", minutes: pomodoroWork)
                }
                Stepper(value: $pomodoroBreak, in: PomodoroSettings.breakMinutesRange) {
                    settingRow("Break", minutes: pomodoroBreak)
                }
            }

            Section {
                Picker("Session goal", selection: $sessionGoal) {
                    ForEach(SessionPlan.goalChoices, id: \.self) { m in
                        if m == 0 { Text("Off").tag(m) } else { Text("\(m) min").tag(m) }
                    }
                }
                Stepper(value: $dailyGoal, in: FocusHistory.dailyGoalRange, step: 10) {
                    settingRow("Daily goal", minutes: dailyGoal)
                }
            } footer: {
                Text("Minutes with a focus score of 70 or more. The daily goal sets your streak.")
            }
        }
        .navigationTitle("Settings")
        .onChange(of: dailyGoal) { _, _ in HistoryStore.shared.refresh() }
    }

    private func settingRow(_ title: LocalizedStringKey, minutes: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text("\(minutes) min").monospacedDigit()
        }
    }
}
