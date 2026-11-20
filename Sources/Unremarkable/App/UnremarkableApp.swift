import AppKit
import RMKit
import SwiftUI

@main
struct UnremarkableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel.shared

    init() {
        // `Unremarkable --mcp-stdio` is a bridge for MCP clients, not the app.
        if CommandLine.arguments.contains("--mcp-stdio") { MCPStdioBridge.run() }
        AppFonts.register()
    }

    var body: some Scene {
        Window("Library", id: "library") {
            LibraryView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands(model: model) }

        MenuBarExtra {
            MeetingMenu().environment(model)
        } label: {
            MeetingMenuLabel()
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(model)
                .appAppearance()
        }
        .defaultSize(width: 880, height: 660)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` starts us as a background process; promote to a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let dir = ProcessInfo.processInfo.environment["UNREMARKABLE_SNAPSHOT_DIR"] { scheduleSnapshots(to: URL(fileURLWithPath: dir)) }
        MainActor.assumeIsolated {
            ServerMode.migrate()
            MCPService.shared.restart()
            CalendarService.shared.start()
            UpdateService.shared.start()
            // Development aid: UNREMARKABLE_UPDATE=install checks the download page and installs any newer version.
            if ProcessInfo.processInfo.environment["UNREMARKABLE_UPDATE"] == "install" {
                Task {
                    await UpdateService.shared.check()
                    FileHandle.standardError.write(Data("UPDATE \(UpdateService.shared.phase) latest=\(UpdateService.shared.latest?.version ?? "-") blocker=\(UpdateService.shared.installBlocker ?? "-")\n".utf8))
                    if UpdateService.shared.updateAvailable { await UpdateService.shared.install() }
                    FileHandle.standardError.write(Data("UPDATE after install: \(UpdateService.shared.phase)\n".utf8))
                }
            }
            // Development aid: UNREMARKABLE_SETTINGS_TAB=<pane> opens Settings on that pane.
            if let tab = ProcessInfo.processInfo.environment["UNREMARKABLE_SETTINGS_TAB"], let pane = SettingsPane(rawValue: tab) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SettingsRouter.open(pane) }
            }
        }
    }

    /// Development aid: periodically writes PNGs of the app's own windows (no Screen Recording permission needed).
    private func scheduleSnapshots(to dir: URL) {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = window.title.isEmpty ? "window-\(i)" : window.title.replacingOccurrences(of: "/", with: "-")
                    do {
                        try rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
                    } catch {
                        FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = SettingsRouter.shared.openWindow = { [openWindow] in openWindow(id: "settings") }
        let _ = model.showLibraryWindow = { [openWindow] in openWindow(id: "library") }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsRouter.open() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { await UpdateService.shared.check() }
                SettingsRouter.open(.updates)
            }
        }
        CommandGroup(after: .newItem) {
            Button("Go to Anything…") { model.showCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("Show Library") { openWindow(id: "library") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandMenu("Meeting") {
            Button(MeetingRecorder.shared.isRecording ? "Stop Recording" : "New Meeting and Record") {
                MeetingActions.toggle()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!MeetingRecorder.isSupported || MeetingRecorder.shared.state == .starting || MeetingRecorder.shared.state == .stopping)
            Button("New Meeting Without Recording") {
                AppModel.shared.openMeeting(MeetingRecorder.shared.newMeeting().id)
            }
        }
        CommandMenu("Sync") {
            Button("Sync Now") { Task { await model.syncNow() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.isPaired || model.isSyncing)
            Button("Rebuild Search Index") { Task { await model.indexText() } }
                .disabled(!model.isPaired)
        }
    }
}

extension View {
    /// Applies the reader theme preference (system / light / dark).
    func readerTheme(_ theme: ReaderTheme) -> some View {
        preferredColorScheme(theme == .system ? nil : theme == .dark ? .dark : .light)
    }
}
