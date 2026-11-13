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
    @AppStorage(AppSettings.Key.personalization) private var personalization = true
    @ObservedObject private var history = HistoryStore.shared

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

            personalizationSection
        }
        .navigationTitle("Settings")
        .onChange(of: dailyGoal) { _, _ in HistoryStore.shared.refresh() }
        .onAppear { history.refresh() }
    }

    /// 个性化打分：开关 + 现在的状态（标签够不够、模型最看重什么）
    @ViewBuilder private var personalizationSection: some View {
        let labels = history.digests.allLabels
        let model = PersonalModel.train(labels)
        Section {
            Toggle("Personalized scoring", isOn: $personalization)
            if personalization {
                if let model {
                    Text("Active · \(model.focusedCount) focused / \(model.distractedCount) distracted labels")
                        .font(.caption2)
                    ForEach(model.explanation.filter { $0.weight != 0 }.prefix(3), id: \.name) { item in
                        HStack(spacing: 4) {
                            Image(systemName: item.weight > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                .foregroundStyle(item.weight > 0 ? .mint : .orange)
                            Text(Self.featureTitle(item.name))
                        }
                        .font(.caption2)
                    }
                } else {
                    let missing = PersonalModel.missingLabels(labels)
                    Text("Needs \(PersonalModel.minLabelsPerClass) labels of each kind. Still missing: \(missing.focused) focused, \(missing.distracted) distracted.")
                        .font(.caption2)
                }
            }
        } footer: {
            Text("Trained on this watch from your Focused / Distracted taps, then blended 50/50 with the built-in score. Nothing leaves the watch. Not validated on real users.")
        }
    }

    /// 特征名 → 给人看的说明（↑ = 让「专注」更可能）
    static func featureTitle(_ name: String) -> LocalizedStringKey {
        switch name {
        case "stillRatio": return "Wrist stillness"
        case "motionMean": return "Wrist motion"
        case "hrDelta": return "Heart rate above baseline"
        default: return "Heart rate variability"
        }
    }

    private func settingRow(_ title: LocalizedStringKey, minutes: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text("\(minutes) min").monospacedDigit()
        }
    }
}
