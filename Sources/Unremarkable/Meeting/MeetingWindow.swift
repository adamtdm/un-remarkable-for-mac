import RMKit
import SwiftUI

/// One meeting: record, type notes while the transcript runs, then read the AI notes and send them to the tablet.
struct MeetingWindow: View {
    let meetingID: String
    @State private var recorder = MeetingRecorder.shared

    var body: some View {
        if recorder.meeting(meetingID) != nil {
            MeetingDetail(meetingID: meetingID)
        } else {
            ContentUnavailableView("Meeting not found", systemImage: "waveform.slash")
        }
    }
}

enum MeetingTab: String, CaseIterable, Identifiable {
    case notes, myNotes, transcript
    var id: String { rawValue }
    var label: String {
        switch self {
        case .notes: return "AI notes"
        case .myNotes: return "My notes"
        case .transcript: return "Transcript"
        }
    }
}

struct MeetingDetail: View {
    let meetingID: String
    @State private var recorder = MeetingRecorder.shared
    @Environment(AppModel.self) private var model
    @State private var tab: MeetingTab = .myNotes
    @State private var showTranscript = true
    @State private var confirmSend = false

    private var meeting: Meeting { recorder.meeting(meetingID) ?? Meeting(id: meetingID) }
    private var isActive: Bool { recorder.activeID == meetingID }
    private var busy: String? { recorder.busy[meetingID] }

    private func binding<T>(_ key: WritableKeyPath<Meeting, T>) -> Binding<T> {
        Binding(get: { meeting[keyPath: key] }, set: { v in
            var m = meeting
            m[keyPath: key] = v
            recorder.update(m)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Paper.border).frame(height: 1)
            if isActive {
                HSplitView {
                    NotesEditor(text: binding(\.myNotes))
                        .frame(minWidth: 320)
                    if showTranscript {
                        LiveTranscript(meeting: meeting, volatile: recorder.volatile)
                            .frame(minWidth: 260, idealWidth: 340)
                    }
                }
            } else {
                content
            }
            if let error = recorder.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { recorder.error = nil }.buttonStyle(.borderless)
                }
                .font(.mono(12.5))
                .padding(10)
                .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
            }
        }
        .background(Paper.background)
        .navigationTitle(meeting.displayTitle)
        .onAppear { tab = defaultTab }
        .onChange(of: isActive) { _, active in if !active { tab = defaultTab } }
        .onChange(of: meeting.aiNotes) { _, new in if !new.isEmpty { tab = .notes } }
    }

    private var defaultTab: MeetingTab {
        if !meeting.aiNotes.isEmpty { return .notes }
        if meeting.myNotes.isEmpty && !meeting.transcript.isEmpty { return .transcript }
        return .myNotes
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Meeting title", text: binding(\.title), prompt: Text(meeting.displayTitle))
                .textFieldStyle(.plain)
                .font(.display(34))
                .tracking(-0.8)
            HStack(spacing: 16) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened).lowercased())
                if isActive {
                    HStack(spacing: 5) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text(Meeting.timestamp(recorder.elapsed)).foregroundStyle(Paper.text).monospacedDigit()
                    }
                    LevelBar(label: "me", level: recorder.levels[.me] ?? 0)
                    if recorder.levels[.them] != nil { LevelBar(label: "them", level: recorder.levels[.them] ?? 0) }
                } else if meeting.duration > 0 {
                    Text(Meeting.timestamp(meeting.duration)).monospacedDigit()
                }
                linkedNotebookMenu
                if let sent = meeting.sentAt {
                    Text("sent " + sent.formatted(.relative(presentation: .named)))
                }
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy.lowercased())
                }
            }
            .font(.mono(12.5))
            .foregroundStyle(Paper.textMuted)
            HStack(spacing: 18) {
                if !isActive {
                    ForEach(MeetingTab.allCases) { t in Chip(title: t.label, selected: tab == t) { tab = t } }
                }
                Spacer(minLength: 12)
                actions
            }
        }
        .padding(.horizontal, Columns.gutter)
        .padding(.top, 16).padding(.bottom, 10)
    }

    private var linkedNotebookMenu: some View {
        let linked = meeting.linkedDocumentID.flatMap { model.byID[$0] }
        let recent = model.documents.filter { !$0.isFolder && !$0.isTrashed && $0.kind != .epub }
            .sorted { $0.lastModified > $1.lastModified }.prefix(12)
        return Menu {
            if let s = recorder.suggestedNotebook(for: meeting), s.id != linked?.id {
                Button("Suggested: \(s.name)") { binding(\.linkedDocumentID).wrappedValue = s.id }
                Divider()
            }
            ForEach(Array(recent)) { d in
                Button(d.name) { binding(\.linkedDocumentID).wrappedValue = d.id }
            }
            if linked != nil {
                Divider()
                Button("Don't Use Tablet Handwriting") { binding(\.linkedDocumentID).wrappedValue = nil }
            }
        } label: {
            Text(linked.map { "notebook: \($0.name)" } ?? "link tablet notebook").underline()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .help("Handwriting from this notebook is read and merged into the AI notes")
    }

    // MARK: Content (not recording)

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            switch tab {
            case .notes:
                if meeting.aiNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("no ai notes yet").font(.display(26)).foregroundStyle(Paper.text)
                        Text("Write notes from your typed notes, the transcript and your tablet handwriting.")
                            .font(.mono(12.5)).foregroundStyle(Paper.textMuted)
                        Button("write notes") { Task { await recorder.generateNotes(meetingID) } }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(busy != nil)
                            .padding(.top, 4)
                    }
                    .padding(Columns.gutter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        MarkdownView(text: meeting.aiNotes)
                            .padding(.horizontal, Columns.gutter).padding(.vertical, 16)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .myNotes:
                NotesEditor(text: binding(\.myNotes))
            case .transcript:
                TranscriptList(meeting: meeting)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        HStack(spacing: 16) {
            if isActive {
                Button(showTranscript ? "hide transcript" : "show transcript") { showTranscript.toggle() }
                    .buttonStyle(MonoButtonStyle())
                Button("■ stop") { Task { await recorder.stop() } }
                    .buttonStyle(AccentButtonStyle())
                .help("Stop recording")
                .disabled(recorder.state != .recording)
            } else {
                Button(meeting.transcript.isEmpty ? "● record" : "● resume") { Task { await recorder.start(meetingID) } }
                    .buttonStyle(MonoButtonStyle(prominent: true))
                .help("Record the microphone and system audio, with live transcription")
                .disabled(recorder.state != .idle || !MeetingRecorder.isSupported)
                Button(meeting.aiNotes.isEmpty ? "write notes" : "rewrite notes") { Task { await recorder.generateNotes(meetingID) } }
                    .buttonStyle(MonoButtonStyle())
                .help("Write notes with AI from your notes, the transcript and tablet handwriting")
                .disabled(busy != nil)
                Button("send to tablet") { confirmSend = true }
                    .buttonStyle(AccentButtonStyle())
                    .help("Send the notes and transcript to your reMarkable as a PDF")
                    .disabled(busy != nil || !model.isPaired)
                    .confirmationDialog("Send \"\(meeting.displayTitle)\" to your reMarkable?", isPresented: $confirmSend) {
                        Button(recorder.sendWouldReplace(meeting) ? "Update Notebook" : meeting.sentAt == nil ? "Send" : "Send Again") {
                            Task { await recorder.sendToTablet(meetingID) }
                        }
                    } message: {
                        if recorder.appendsToLinked(meeting) {
                            Text("The notes are added as new page\(recorder.transcriptOnTablet ? "s" : "") after \"\(model.byID[meeting.linkedDocumentID ?? ""]?.name ?? "the linked notebook")\", below your handwritten notes\(meeting.appendedPageIDs.isEmpty ? "" : ", replacing the pages added last time").")
                        } else if recorder.sendWouldReplace(meeting) {
                            Text("The notebook on your tablet is replaced with the latest notes. Anything you wrote on it is lost.")
                        } else if recorder.sendFormat == "pdf" {
                            Text("It's uploaded as a PDF into your \"\(recorder.folderName)\" folder\(meeting.sentAt == nil ? "" : ". It was already sent once, so this adds a second copy").")
                        } else {
                            Text("It's created as a typed notebook in your \"\(recorder.folderName)\" folder, with the transcript on the following pages and room to write.")
                        }
                    }
                Menu {
                    Button("Copy as Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(recorder.exportMarkdown(meeting), forType: .string)
                    }
                    Button("Show Recording in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([recorder.store.folder(for: meetingID)])
                    }
                } label: { Text("more").font(.mono(12.5)).foregroundStyle(Paper.textMuted) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
        }
    }
}

// MARK: - Pieces

struct NotesEditor: View {
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 15))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, Columns.gutter - 5).padding(.vertical, 14)
            if text.isEmpty {
                Text("Type your notes… Short points are fine; the AI fills in the detail from the transcript.")
                    .font(.system(size: 15))
                    .foregroundStyle(Paper.textMuted)
                    .padding(.horizontal, Columns.gutter).padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct LevelBar: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Paper.raised)
                    Rectangle().fill(Paper.text).frame(width: g.size.width * CGFloat(level))
                }
            }
            .frame(width: 44, height: 3)
            .animation(.linear(duration: 0.1), value: level)
        }
    }
}

struct LiveTranscript: View {
    let meeting: Meeting
    let volatile: [Speaker: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(text: "live transcript").padding(.horizontal, Columns.gutter).frame(height: Columns.header, alignment: .leading)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(meeting.transcript.suffix(300)) { s in
                            SegmentRow(segment: s, label: meeting.label(for: s))
                        }
                        ForEach(Speaker.allCases, id: \.self) { sp in
                            if let v = volatile[sp], !v.isEmpty {
                                SegmentRow(segment: TranscriptSegment(speaker: sp, start: 0, end: 0, text: v), live: true)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Columns.gutter).padding(.bottom, 12)
                }
                .onChange(of: meeting.transcript.count) { proxy.scrollTo("end") }
                .onChange(of: volatile) { proxy.scrollTo("end") }
            }
            if meeting.transcript.isEmpty && volatile.values.allSatisfy(\.isEmpty) {
                Text("Listening… Speech appears here a moment after it's spoken.")
                    .font(.mono(12.5)).foregroundStyle(Paper.textMuted).padding(Columns.gutter)
            }
        }
        .overlay(alignment: .leading) { Rectangle().fill(Paper.border).frame(width: 1) }
    }
}

/// The voices found in "Them", each with a name field (attendees offered from the calendar event).
struct VoicesBar: View {
    let meeting: Meeting
    @State private var recorder = MeetingRecorder.shared
    @State private var result: String?

    var body: some View {
        let voices = meeting.voices
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(voices.isEmpty ? "Everyone on the call is \"Them\"" : "\(voices.count) voices on the call", systemImage: "person.2.wave.2")
                    .font(.callout.weight(.medium))
                if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if voices.isEmpty {
                    Button("Separate Voices") { Task { await separate() } }
                        .disabled(recorder.busy[meeting.id] != nil)
                        .help("Tell the people on the call apart by their voices, from the recorded audio")
                } else {
                    Button("Find Again") { Task { await separate() } }
                        .disabled(recorder.busy[meeting.id] != nil)
                    Button("Undo") { recorder.clearVoices(meeting.id); result = nil }
                        .help("Go back to one \"Them\"")
                }
            }
            if !voices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(voices, id: \.self) { v in VoiceNameField(meeting: meeting, voice: v) }
                    }
                }
                Text("Name each voice; give two voices the same name if they're one person.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
    }

    private func separate() async {
        let n = await recorder.findVoices(meeting.id)
        result = n > 1 ? nil : "Only one voice was found."
    }
}

struct VoiceNameField: View {
    let meeting: Meeting
    let voice: Int
    @State private var name = ""

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(VoiceNameField.color(voice)).frame(width: 8, height: 8).accessibilityHidden(true)
            TextField("Them \(voice)", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .onSubmit(save)
                .accessibilityLabel("Name for voice \(voice)")
            if !meeting.attendees.isEmpty {
                Menu {
                    ForEach(meeting.attendees, id: \.self) { a in Button(a) { name = a; save() } }
                } label: { Image(systemName: "person.crop.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pick an attendee")
                .accessibilityLabel("Pick an attendee for voice \(voice)")
            }
        }
        .onAppear { name = meeting.voiceNames[String(voice)] ?? "" }
        .onChange(of: name) { save() }
    }

    private func save() { MeetingRecorder.shared.nameVoice(meeting.id, voice: voice, as: name) }

    static func color(_ voice: Int) -> Color {
        [Color.purple, .orange, .teal, .pink, .brown, .indigo, .mint, .cyan][(voice - 1) % 8]
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    var live = false
    var label: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label ?? segment.speaker.label).fontWeight(.semibold)
                    .foregroundStyle(segment.speaker == .me ? Paper.text : segment.voice.map(VoiceNameField.color) ?? Paper.textSecondary)
                if !live { Text(Meeting.timestamp(segment.start)).foregroundStyle(Paper.textMuted).monospacedDigit() }
            }
            .font(.mono(11.5))
            Text(segment.text).foregroundStyle(live ? .secondary : .primary).textSelection(.enabled)
        }
    }
}

struct TranscriptList: View {
    let meeting: Meeting
    @State private var filter = ""

    var body: some View {
        let lines = meeting.transcriptText.components(separatedBy: "\n").filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
        VStack(spacing: 0) {
            if meeting.transcript.isEmpty {
                Text("no transcript yet. record to transcribe the meeting.").font(.mono(12.5)).foregroundStyle(Paper.textMuted)
                    .padding(Columns.gutter).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                RuledField(prompt: "Filter transcript", text: $filter).frame(maxWidth: 320, alignment: .leading)
                    .padding(.horizontal, Columns.gutter).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if meeting.transcript.contains(where: { $0.speaker == .them }), meeting.audioFiles.values.contains(Speaker.them.rawValue) {
                    VoicesBar(meeting: meeting).padding(.horizontal, Columns.gutter).padding(.bottom, 8)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 13.5)).foregroundStyle(Paper.text).textSelection(.enabled)
                                .frame(maxWidth: 760, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, Columns.gutter).padding(.bottom, 24)
                }
            }
        }
    }
}

/// Renders the Markdown subset the AI writes: headings, bullets, checkboxes, numbered lists, paragraphs.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, raw in
                line(raw)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func line(_ raw: String) -> some View {
        let indent = CGFloat(raw.prefix { $0 == " " }.count / 2) * 18
        let l = raw.trimmingCharacters(in: .whitespaces)
        if l.isEmpty {
            Color.clear.frame(height: 4)
        } else if l.hasPrefix("#") {
            let level = l.prefix { $0 == "#" }.count
            inline(String(l.dropFirst(level)).trimmingCharacters(in: .whitespaces))
                .font(level <= 2 ? .display(24) : .mono(13, weight: .semibold))
                .padding(.top, level <= 2 ? 12 : 6)
        } else if let m = l.firstMatch(of: /^[-*+]\s+\[( |x|X)\]\s+(.*)$/) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: m.1 == " " ? "square" : "checkmark.square.fill").foregroundStyle(.secondary)
                inline(String(m.2)).strikethrough(m.1 != " ")
            }
            .padding(.leading, indent)
        } else if let m = l.firstMatch(of: /^[-*+•]\s+(.*)$/) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(indent > 0 ? "◦" : "•").foregroundStyle(.secondary)
                inline(String(m.1))
            }
            .padding(.leading, indent)
        } else if let m = l.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(m.1).").foregroundStyle(.secondary).monospacedDigit()
                inline(String(m.2))
            }
            .padding(.leading, indent)
        } else {
            inline(l)
        }
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s))
    }
}
