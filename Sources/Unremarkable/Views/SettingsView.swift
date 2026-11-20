import RMKit
import SwiftUI

struct ReaderSettings: View {
    @AppStorage("readerPageTurn") private var pageTurn = "both"
    @AppStorage("deviceProfile") private var device = DeviceProfile.paperPro.rawValue
    @AppStorage("invertPDFs") private var invertPDFs = true
    @AppStorage("spreadCoverAlone") private var coverAlone = true

    var body: some View {
        Form {
            SettingsHeader(.reading)
            Section("Turning pages") {
                Picker("Turn pages with", selection: $pageTurn) {
                    Text("Swipe and click edges").tag("both")
                    Text("Swipe only").tag("swipe")
                    Text("Click edges only").tag("tap")
                }
                .pickerStyle(.radioGroup)
                Text("Swipe left or right with two fingers on the trackpad, or click the left or right edge of the page. The arrow keys always work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Darken PDF pages in dark mode", isOn: $invertPDFs)
            Text("Text pages are inverted to a dark canvas. Pages that look like comics or artwork keep their colours. Override per document from the reader toolbar.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show the cover on its own in two-page view", isOn: $coverAlone)
            Picker("My tablet", selection: $device) {
                ForEach(DeviceProfile.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Text("Used to size converted documents and generated pages for your screen. Ink is always placed using each page's own tablet size.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct MeetingSettings: View {
    @AppStorage("meetingCaptureSystemAudio") private var captureSystemAudio = true
    @AppStorage("meetingAutoNotes") private var autoNotes = true
    @AppStorage("meetingSendFormat") private var sendFormat = "notebook"
    @AppStorage("meetingFolderName") private var folderName = "Meeting Notes"
    @AppStorage("quickNotesNotebook") private var quickNotes = "Quick Notes"
    @AppStorage("calendarPrompts") private var calendarPrompts = true
    @AppStorage("calendarLeadMinutes") private var lead = 1
    @AppStorage("meetingAppendToLinked") private var appendToLinked = true
    @AppStorage("meetingTranscriptOnTablet") private var transcriptOnTablet = false
    @State private var calendar = CalendarService.shared

    var body: some View {
        Form {
            SettingsHeader(.meetings)
            Section("Calendar") {
                if calendar.hasAccess {
                    Toggle("Remind me to record meetings", isOn: $calendarPrompts)
                    Picker("Remind", selection: $lead) {
                        Text("When it starts").tag(0)
                        Text("1 minute before").tag(1)
                        Text("5 minutes before").tag(5)
                    }
                    .disabled(!calendarPrompts)
                } else {
                    Button("Connect Calendars…") { Task { await calendar.requestAccess() } }
                }
                Toggle("Add notes to the tablet's meeting page when there is one", isOn: $appendToLinked)
                Text("Meetings started from your calendar link to the notebook your reMarkable made for the event. Notes are added as pages after it, below your handwriting.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Include the transcript on the tablet", isOn: $transcriptOnTablet)
            }
            Toggle("Record the other people on calls (system audio)", isOn: $captureSystemAudio)
            Toggle("Write AI notes when a recording stops", isOn: $autoNotes)
            Picker("Send to tablet as", selection: $sendFormat) {
                Text("Typed notebook (editable on the tablet)").tag("notebook")
                Text("PDF").tag("pdf")
            }
            TextField("Tablet folder", text: $folderName)
            Text("Meeting notes go into this folder on your reMarkable if it exists, otherwise My files.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Quick notes") {
                TextField("Notebook", text: $quickNotes)
                Text("Quick notes from the menu bar are added to this notebook, created if needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct MCPSettings: View {
    @State private var mcp = MCPService.shared
    @AppStorage("mcpEnabled") private var enabled = true
    @AppStorage("mcpScope") private var scope = "network"
    @AppStorage("mcpPort") private var port = Int(MCPService.defaultPort)
    @State private var copied: String?

    var body: some View {
        Form {
            SettingsHeader(.mcp)
            if !ServerMode.isOn {
                Text("The MCP server runs when Server › Operate as a server is on.").foregroundStyle(.secondary)
            }
            Toggle("MCP server", isOn: $enabled).onChange(of: enabled) { mcp.restart() }
            LabeledContent("Status") {
                if mcp.running { Label("Running on port \(port)", systemImage: "circle.fill").foregroundStyle(.green) }
                else { Label(mcp.lastError ?? "Off", systemImage: "circle").foregroundStyle(.secondary) }
            }
            Picker("Available to", selection: $scope) {
                Text("This Mac only").tag("localhost")
                Text("Devices on my network").tag("network")
            }
            .onChange(of: scope) { mcp.restart() }
            TextField("Port", value: $port, format: .number.grouping(.never)).onSubmit { mcp.restart() }
            Section("Connect a client") {
                copyRow("Claude Code", "claude mcp add --transport http unremarkable \(scope == "network" ? mcp.networkURL : mcp.localURL) --header \"Authorization: Bearer \(mcp.token)\"")
                copyRow("Claude Desktop (command)", "{\"mcpServers\": {\"unremarkable\": {\"command\": \"\(Bundle.main.executablePath ?? "/Applications/Unremarkable.app/Contents/MacOS/Unremarkable")\", \"args\": [\"--mcp-stdio\"]}}}")
                copyRow("URL", scope == "network" ? mcp.networkURL : mcp.localURL)
                copyRow("Token", mcp.token)
                Button("New Token") { mcp.regenerateToken() }
                Text("Clients send the token as \"Authorization: Bearer …\". 20 tools: the web app's library, tasks and notebook tools, plus ask_notes and meetings. Excluded folders are hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !mcp.recent.isEmpty {
                Section("Recent requests") {
                    ForEach(mcp.recent.prefix(6), id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            HStack {
                Text(value).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Button(copied == label ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = label
                }
            }
        }
    }
}

struct SearchSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("searchNotesOnly") private var notesOnly = false
    @AppStorage("companionSearch") private var companion = false
    @AppStorage("companionURL") private var companionURL = AppModel.defaultCompanionURL
    @State private var rebuilding = false
    @State private var companionStatus: String?

    var body: some View {
        Form {
            SettingsHeader(.search)
            Picker("Search", selection: $notesOnly) {
                Text("All documents").tag(false)
                Text("Notes only").tag(true)
            }
            Section("Excluded from search contents, tasks and Ask") {
                let items = model.explicitExclusions.compactMap { model.byID[$0] }.sorted { $0.name < $1.name }
                if items.isEmpty {
                    Text("Nothing excluded. Right-click a folder or document in the library and choose Exclude from Search & Tasks, e.g. for comics and novels.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(items) { d in
                    HStack {
                        Label(d.name, systemImage: d.isFolder ? "folder" : d.kind.symbol)
                        Spacer()
                        Button("Include") { model.setExcluded(d, false) }
                    }
                }
                Text("Excluded items still show up when you search for their title.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Companion server") {
                Toggle(isOn: $companion) {
                    Text("Include results from my Un-remarkable web app")
                    Text("Adds the server's index (its handwriting OCR and highlights) to search. Results that are already found here aren't repeated.")
                }
                if companion {
                    TextField("Server address", text: $companionURL, prompt: Text(AppModel.exampleCompanionURL))
                    HStack {
                        Button("Test Connection") { Task { await testCompanion() } }
                        if let companionStatus { Text(companionStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Index") {
                HStack {
                    Button(rebuilding ? "Rebuilding…" : "Rebuild Search Index and Task Scan") {
                        rebuilding = true
                        Task { await model.rebuildIndexes(); rebuilding = false }
                    }
                    .disabled(rebuilding || !model.isPaired)
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension SearchSettings {
    func testCompanion() async {
        guard let url = URL(string: companionURL.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
            companionStatus = "Enter an address such as \(AppModel.exampleCompanionURL)."
            return
        }
        companionStatus = "Connecting…"
        do {
            let hits = try await CompanionSearchProvider(base: url).search("the")
            companionStatus = "Connected: \(hits.count) result\(hits.count == 1 ? "" : "s") for a test search."
        } catch {
            companionStatus = "Couldn't reach it: \(error.localizedDescription)"
        }
    }
}

struct TaskSettings: View {
    @AppStorage("tasksNotebookEnabled") private var notebook = true
    @AppStorage("tasksNotebookTitle") private var title = "Tasks"
    @AppStorage("tasksHandwriting") private var handwriting = true
    @AppStorage("tasksFromMeetings") private var meetings = true

    var body: some View {
        Form {
            SettingsHeader(.tasks)
            Toggle("Keep a Tasks notebook on my reMarkable", isOn: $notebook)
            if !ServerMode.isOn {
                Text("The Tasks notebook is kept only when Server › Operate as a server is on. Tasks still work in the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Notebook name", text: $title).disabled(!notebook)
            Text("Rebuilt after each sync when tasks change; an existing notebook with this name is reused. Tick a box in it on the tablet to complete the task here too. Handwriting added to it is replaced on the next update. If the Un-remarkable web server also runs, untick \"Keep Tasks notebook on tablet\" there so they don't overwrite each other.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Read handwritten * tasks", isOn: $handwriting)
            Text(UserDefaults.standard.string(forKey: "ocrEngine") == "ai"
                 ? (AISettings.current.provider.supportsImages
                    ? "Pages changed since the last scan are sent to \(AISettings.current.provider.displayName), up to 20 per scan."
                    : "Server › Read with is set to AI, which needs a provider that reads images (Gemini, OpenAI or Ollama with a vision model).")
                 : "Pages changed since the last scan are converted by reMarkable's handwriting service, up to 20 per scan. Tick them off in the Tasks notebook or here.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Add my action items from meeting notes", isOn: $meetings)
        }
        .formStyle(.grouped)
    }
}

struct AISettingsView: View {
    @AppStorage("aiSettings") private var stored = ""
    @State private var settings = AISettings()
    @State private var apiKey = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            SettingsHeader(.ai)
            Picker("Provider", selection: $settings.provider) {
                ForEach(AIProviderKind.available) { Text($0.displayName).tag($0) }
            }
            if settings.provider.usesNetworkSettings {
                TextField("Model", text: $settings.model, prompt: Text(settings.provider.defaultModel))
                TextField("Base URL", text: $settings.baseURL, prompt: Text(settings.provider.defaultBaseURL))
            } else {
                Text("Runs on this Mac. Nothing leaves your computer. Can't read images, but handwriting is still converted by reMarkable's service.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.provider.needsAPIKey {
                SecureField("API key", text: $apiKey)
                Text("Stored only on this Mac, readable by your user account alone.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(testing ? "Testing…" : "Test Connection", action: test).disabled(testing)
                if let testResult { Text(testResult).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            Text("Same providers as the Un-remarkable web app. Used to write meeting notes from your notes, the transcript and your tablet handwriting.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: settings) { old, new in
            if old.provider != new.provider {
                apiKey = AISettings.apiKey(for: new.provider)
                if settings.model == old.provider.defaultModel || settings.model.isEmpty { settings.model = new.provider.defaultModel }
            }
            save()
        }
        .onChange(of: apiKey) { AISettings.setAPIKey(apiKey, for: settings.provider) }
    }

    private func load() {
        if let d = stored.data(using: .utf8), let s = try? JSONDecoder().decode(AISettings.self, from: d) { settings = s }
        apiKey = AISettings.apiKey(for: settings.provider)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(settings) { stored = String(decoding: d, as: UTF8.self) }
    }

    private func test() {
        testing = true
        testResult = nil
        let provider = AIProvider(settings: settings, apiKey: apiKey)
        Task {
            do {
                let r = try await provider.testConnection()
                testResult = "✓ \(r.reply) in \(String(format: "%.1f", r.latency))s"
            } catch {
                testResult = "✗ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
