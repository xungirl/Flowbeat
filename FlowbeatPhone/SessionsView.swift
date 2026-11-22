import FlowbeatCore
import FlowbeatPhoneData
import FlowbeatPhoneUI
import SwiftData
import SwiftUI

/// 记录页：按天分组的每一次专注，点进去看时间线、写备注、导出、删除。
struct SessionsView: View {
    @Query(sort: \StoredSession.start, order: .reverse) private var sessions: [StoredSession]
    @Environment(\.modelContext) private var context
    @State private var search = ""
    @State private var path: [StoredSession] = []

    private var filtered: [StoredSession] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? sessions : sessions.filter { $0.note.localizedCaseInsensitiveContains(q) }
    }

    /// 按当地日期分组，最新的一天在前
    private var days: [(day: Date, items: [StoredSession])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.start) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.start > $1.start }) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No focus sessions yet", systemImage: "applewatch")
                    } description: {
                        Text("Sessions from your Apple Watch appear here after you end them.")
                    }
                } else {
                    List {
                        ForEach(days, id: \.day) { group in
                            Section {
                                ForEach(group.items) { s in
                                    NavigationLink(value: s) { StoredSessionRow(session: s) }
                                }
                                .onDelete { offsets in
                                    for s in offsets.map({ group.items[$0] }) {
                                        try? SessionLibrary.delete(s, from: context, raw: PhoneStorage.raw)
                                    }
                                }
                            } header: {
                                Text(group.day.formatted(.dateTime.weekday(.wide).month().day()))
                            }
                        }
                    }
                    .searchable(text: $search, prompt: Text("Search notes"))
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: StoredSession.self) { SessionDetailView(session: $0) }
        }
        #if targetEnvironment(simulator)
        // -openFirst：直接打开最新一条（CI 和 App Store 截图详情页用）
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-openFirst"), let first = sessions.first { path = [first] }
        }
        #endif
    }
}

struct StoredSessionRow: View {
    let session: StoredSession

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.gray.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: (session.averageScore ?? 0) / 100)
                    .stroke(PhoneTheme.color(for: session.averageScore),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(session.averageScore.map { "\(Int($0))" } ?? "--").font(.caption.bold()).monospacedDigit()
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text((session.start..<max(session.start, session.end)).formatted(.interval.hour().minute()))
                        .font(.subheadline.weight(.medium))
                    if session.sessionMode == .pomodoro {
                        Image(systemName: "timer").font(.caption).foregroundStyle(.secondary)
                    }
                    if session.goalMet == true {
                        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.mint)
                    }
                }
                Text("\(session.focusedMinutes) min focused · \(Self.duration(session.durationSeconds))")
                    .font(.caption).foregroundStyle(.secondary)
                if !session.note.isEmpty {
                    Text(session.note).font(.caption).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

struct SessionDetailView: View {
    @Bindable var session: StoredSession
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var record: SessionRecord?
    @State private var exportURL: URL?
    @FocusState private var editingNote: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Note", systemImage: "square.and.pencil").font(.headline)
                        TextField("What were you working on?", text: $session.note, axis: .vertical)
                            .lineLimit(1...5)
                            .focused($editingNote)
                            .submitLabel(.done)
                    }
                }
                if let goal = session.goalMinutes {
                    Card {
                        Label(session.goalMet == true ? "Goal reached: \(session.focusedMinutes) of \(goal) min"
                                                      : "Goal: \(session.focusedMinutes) of \(goal) min",
                              systemImage: session.goalMet == true ? "checkmark.seal.fill" : "target")
                            .foregroundStyle(session.goalMet == true ? .mint : .primary)
                    }
                }
                if let record {
                    SessionDetailContent(record: record)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(session.start.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let exportURL {
                    ShareLink(item: exportURL) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(Text("Export session"))
                }
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel(Text("Delete session"))
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editingNote = false }
            }
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? SessionLibrary.delete(session, from: context, raw: PhoneStorage.raw)
                dismiss()
            }
        } message: {
            Text("It's removed from this iPhone and from iCloud. The copy on your watch isn't sent again.")
        }
        .task(id: session.name) {
            record = session.record()
            exportURL = Self.writeExport(session)
        }
        .onChange(of: editingNote) { _, editing in
            if !editing { try? context.save() }
        }
        .onDisappear { try? context.save() }
    }

    /// 导出和手表存档一样的 JSON（逐秒样本，本机有原始存档时带心率），文件名是开始时间
    static func writeExport(_ s: StoredSession) -> URL? {
        guard let data = PhoneStorage.raw.read(name: s.name) ?? s.recordData else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Flowbeat-\(s.name).json")
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }
}
