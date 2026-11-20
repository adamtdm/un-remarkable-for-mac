import RMKit
import SwiftUI

@MainActor
enum MeetingActions {
    /// Starts a new meeting and opens its window, or stops the one being recorded.
    static func toggle() {
        let recorder = MeetingRecorder.shared
        if recorder.isRecording {
            Task { await recorder.stop() }
        } else {
            let m = recorder.newMeeting()
            AppModel.shared.openMeeting(m.id)
            Task { await recorder.start(m.id) }
        }
    }
}

/// Meetings list shown in the library window.
struct MeetingsListView: View {
    @State private var recorder = MeetingRecorder.shared
    @State private var query = ""

    var body: some View {
        let items = recorder.meetings.filter { m in
            query.isEmpty || m.displayTitle.localizedCaseInsensitiveContains(query)
                || m.myNotes.localizedCaseInsensitiveContains(query) || m.aiNotes.localizedCaseInsensitiveContains(query)
                || m.transcript.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
        VStack(spacing: 0) {
            ColumnHeader(title: "meetings") {
                Text("\(recorder.meetings.count)").font(.mono(12.5)).foregroundStyle(Paper.textMuted).monospacedDigit()
                Spacer(minLength: 12)
                RuledField(prompt: "Search meetings", text: $query).frame(maxWidth: 220)
                Button(recorder.isRecording ? "stop recording" : "new meeting") { MeetingActions.toggle() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!MeetingRecorder.isSupported)
                    .help("Record a meeting (⇧⌘M)")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    UpNextView()
                    if recorder.meetings.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("no meetings yet").font(.display(26)).foregroundStyle(Paper.text)
                            Text("Record a meeting to get a live transcript on this Mac, then AI notes that include what you wrote on your tablet. Shortcut: ⇧⌘M.")
                                .font(.mono(12.5)).foregroundStyle(Paper.textMuted).frame(maxWidth: 520, alignment: .leading)
                        }
                    } else {
                        RuledList(title: query.isEmpty ? "recorded" : "\(items.count) matching", more: nil) {
                            ForEach(items) { m in
                                MeetingRow(meeting: m, recording: recorder.activeID == m.id)
                                    .contextMenu {
                                        Button("Open") { AppModel.shared.openMeeting(m.id) }
                                        Button("Delete", role: .destructive) { recorder.delete(m.id) }.disabled(recorder.activeID == m.id)
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, Columns.gutter).padding(.top, 14).padding(.bottom, 32)
            }
        }
        .navigationTitle("Meetings")
    }
}

/// A meeting as an index row: title and first line of its notes; date, length and whether it's on the tablet.
struct MeetingRow: View {
    let meeting: Meeting
    let recording: Bool
    @State private var hover = false

    var body: some View {
        Button { AppModel.shared.openMeeting(meeting.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if recording { Circle().fill(Color.red).frame(width: 7, height: 7).accessibilityLabel("Recording") }
                        Text(meeting.displayTitle).font(.mono(12.5, weight: .medium)).foregroundStyle(Paper.text).lineLimit(1)
                    }
                    Text(snippet).font(.mono(12)).foregroundStyle(Paper.textMuted).lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened).lowercased())
                    HStack(spacing: 10) {
                        if meeting.sentAt != nil { Text("on tablet") }
                        if !meeting.aiNotes.isEmpty { Text("notes") }
                        if meeting.duration > 0 { Text(Meeting.timestamp(meeting.duration)) }
                    }
                }
                .font(.mono(12)).foregroundStyle(Paper.textMuted).monospacedDigit()
            }
            .padding(.vertical, 7)
            .background(hover ? Paper.raised : .clear)
            .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var snippet: String {
        if let summary = meeting.aiNotes.components(separatedBy: "\n").first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) { return summary }
        if !meeting.myNotes.isEmpty { return meeting.myNotes.replacingOccurrences(of: "\n", with: " · ") }
        return meeting.transcript.first?.text ?? "No notes yet"
    }
}

/// Menu bar: start or stop a meeting from anywhere while you work.
struct MeetingMenu: View {
    @State private var recorder = MeetingRecorder.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let m = recorder.active {
                HStack {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text(m.displayTitle).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Text(Meeting.timestamp(recorder.elapsed)).monospacedDigit().foregroundStyle(.secondary)
                }
                if let last = (recorder.volatile.values.first { !$0.isEmpty }) ?? m.transcript.last?.text {
                    Text(last).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack {
                    Button("Open Meeting") { AppModel.shared.openMeeting(m.id); NSApp.activate() }
                    Spacer()
                    Button("Stop") { Task { await recorder.stop() } }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Un-remarkable").font(.headline)
                QuickNoteField()
                Divider()
                if let next = CalendarService.shared.upcoming.first(where: { $0.isNow || $0.start.timeIntervalSinceNow < 3600 }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(next.title).lineLimit(1)
                            Text(next.isNow ? "Now" : next.start.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Record") { CalendarService.shared.record(next); NSApp.activate() }
                    }
                    Divider()
                }
                Button {
                    MeetingActions.toggle()
                    NSApp.activate()
                } label: {
                    Label("Start Meeting", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!MeetingRecorder.isSupported || recorder.state != .idle)
                if let error = recorder.error { Text(error).font(.caption).foregroundStyle(.orange) }
                if !recorder.meetings.isEmpty {
                    Divider()
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    ForEach(recorder.meetings.prefix(5)) { m in
                        Button {
                            AppModel.shared.openMeeting(m.id)
                            NSApp.activate()
                        } label: {
                            HStack {
                                Text(m.displayTitle).lineLimit(1)
                                Spacer()
                                Text(m.startedAt.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Divider()
            HStack {
                Button("Library") { openWindow(id: "library"); NSApp.activate() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct MeetingMenuLabel: View {
    @State private var recorder = MeetingRecorder.shared

    var body: some View {
        if recorder.isRecording {
            Label(Meeting.timestamp(recorder.elapsed), systemImage: "record.circle.fill")
        } else {
            Image(systemName: "waveform")
        }
    }
}

/// Today's calendar meetings with a Record button (or a prompt to connect calendars).
struct UpNextView: View {
    @State private var calendar = CalendarService.shared
    @State private var recorder = MeetingRecorder.shared

    var body: some View {
        if !calendar.hasAccess {
            HStack(spacing: 14) {
                Text("Connect your calendars to be reminded to record meetings, with titles and attendees filled in.")
                    .font(.mono(12.5)).foregroundStyle(Paper.textSecondary)
                Button("connect calendars") { Task { await calendar.requestAccess() } }
                    .buttonStyle(MonoButtonStyle(prominent: true))
            }
        } else {
            let today = calendar.upcoming.filter { Calendar.current.isDateInToday($0.start) || $0.isNow }
            RuledList(title: today.isEmpty ? "no more meetings today" : "up next", more: nil) {
                ForEach(today.prefix(5)) { m in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.start.formatted(date: .omitted, time: .shortened)).foregroundStyle(Paper.text).monospacedDigit()
                            Text(m.isNow ? "now" : m.start.formatted(.relative(presentation: .named))).foregroundStyle(m.isNow ? Paper.accent : Paper.textMuted)
                        }
                        .frame(width: 84, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(m.title).foregroundStyle(Paper.text).lineLimit(1)
                                if m.hasVideoLink { Image(systemName: "video").font(.system(size: 10)).foregroundStyle(Paper.textMuted) }
                            }
                            let nb = CalendarService.calendarNotebook(title: m.title, date: m.start)
                            Text(nb.map { "notes go to \($0.name) on your tablet" } ?? (m.attendees.isEmpty ? m.calendar : m.attendees.prefix(3).joined(separator: ", ")))
                                .foregroundStyle(Paper.textMuted).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        Button("● record") { calendar.record(m) }
                            .buttonStyle(MonoButtonStyle(prominent: true))
                            .disabled(recorder.isRecording || !MeetingRecorder.isSupported)
                            .accessibilityLabel("Record \(m.title)")
                    }
                    .font(.mono(12.5))
                    .padding(.vertical, 7)
                    .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
                }
            }
        }
    }
}
