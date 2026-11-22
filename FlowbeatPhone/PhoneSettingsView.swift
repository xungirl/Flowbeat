import FlowbeatCore
import FlowbeatPhoneData
import SwiftData
import SwiftUI

/// 设置页：每日目标（同步到手表）、数据存在哪、导出 CSV、关于。
struct PhoneSettingsView: View {
    let storageLocation: FlowbeatStore.Location
    @Query(sort: \StoredSession.start, order: .reverse) private var sessions: [StoredSession]
    @AppStorage("goal.dailyMinutes") private var dailyGoal = FocusHistory.defaultDailyGoalMinutes
    @EnvironmentObject private var watch: WatchLink
    @State private var csvURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $dailyGoal, in: FocusHistory.dailyGoalRange, step: 10) {
                        LabeledContent("Daily goal", value: String(localized: "\(dailyGoal) min"))
                    }
                } footer: {
                    Text("Minutes with a focus score of 70 or more. The daily goal sets your streak and syncs with your watch.")
                }

                Section {
                    LabeledContent("Sessions", value: "\(sessions.count)")
                    LabeledContent("Stored in") { Text(storageText) }
                    if let csvURL, !sessions.isEmpty {
                        ShareLink(item: csvURL) { Label("Export all as CSV", systemImage: "tablecells") }
                    }
                } header: {
                    Text("Your data")
                } footer: {
                    Text(storageFooter)
                }

                Section {
                    Label(watch.status.text, systemImage: watch.status.symbol)
                    if let last = watch.lastReceived {
                        LabeledContent("Last session received", value: last.formatted(date: .omitted, time: .shortened))
                    }
                    if let error = watch.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                } header: {
                    Text("Apple Watch")
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                    Text("Flowbeat estimates focus from heart rate and wrist motion. The score is an estimate, not a measurement, and it isn't a medical device.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("No account, no tracking, no ads. Sessions never leave your devices except through your own iCloud.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .onChange(of: dailyGoal) { _, new in watch.dailyGoalChanged(to: new) }
            .task(id: sessions.count) { csvURL = Self.writeCSV(sessions) }
        }
    }

    private var storageText: LocalizedStringKey {
        switch storageLocation {
        case .iCloud: return "This iPhone + iCloud"
        case .local: return "This iPhone"
        case .inMemory: return "Temporary (demo)"
        }
    }

    private var storageFooter: LocalizedStringKey {
        switch storageLocation {
        case .iCloud:
            return "Sessions sync to your private iCloud database, so a new iPhone gets them back. Only your Apple Account can read them. Turn it off in iOS Settings → your name → iCloud."
        case .local:
            return "Sessions are stored only on this iPhone."
        case .inMemory:
            return "Demo data, not saved."
        }
    }

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    static func writeCSV(_ sessions: [StoredSession]) -> URL? {
        guard !sessions.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Flowbeat-sessions.csv")
        return (try? SessionCSV.make(sessions).write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}
