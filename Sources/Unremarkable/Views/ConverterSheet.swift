import RMKit
import SwiftUI
import UniformTypeIdentifiers

/// The converter: options, progress and a before/after result with Send or Save.
struct ConverterSheet: View {
    enum Source: Equatable {
        case file(URL)
        case document(DocumentItem)
        var name: String {
            switch self {
            case .file(let u): return u.deletingPathExtension().lastPathComponent
            case .document(let d): return d.coverTitle
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: Source
    @State var folder: String = ""
    @AppStorage("converterQuality") private var quality = 3
    @AppStorage("deviceProfile") private var deviceID = DeviceProfile.paperPro.rawValue
    @AppStorage("converterSplitSpreads") private var split = true
    @AppStorage("converterManga") private var manga = false
    @State private var progress: (Int, Int)?
    @State private var result: Converter.Result?
    @State private var error: String?
    @State private var sent = false

    private var device: DeviceProfile { DeviceProfile(rawValue: deviceID) ?? .paperPro }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Optimise for your reMarkable").font(.display(22))
            Text(source.name).font(.headline).foregroundStyle(Paper.textSecondary).lineLimit(2)
            Form {
                Picker("Tablet", selection: $deviceID) {
                    ForEach(DeviceProfile.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Quality")
                        Slider(value: Binding(get: { Double(quality) }, set: { quality = Int($0.rounded()) }), in: 1...5, step: 1)
                        Text(QualityProfile.stop(quality).name).frame(width: 70, alignment: .trailing).monospacedDigit()
                    }
                    Text(QualityProfile.stop(quality).description).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Split double-page spreads", isOn: $split)
                Toggle("Right-to-left (manga) order", isOn: $manga).disabled(!split)
                Picker("Send to folder", selection: $folder) {
                    Text("My files").tag("")
                    ForEach(model.documents.filter { $0.isFolder && !$0.isTrashed }.sorted { $0.name < $1.name }) { Text($0.name).tag($0.id) }
                }
            }
            .formStyle(.grouped)
            .disabled(progress != nil && result == nil)
            Text("Best for scanned comics, magazines and image-heavy PDFs: pages become images sized for the screen. Text PDFs can get bigger.")
                .font(.caption).foregroundStyle(Paper.textMuted)

            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let progress, result == nil {
                ProgressView(value: Double(progress.0), total: Double(max(progress.1, 1))) { Text("Converting page \(progress.0) of \(progress.1)…") }
            }
            if let result {
                let before = result.inputBytes, after = result.pdf.count
                HStack(spacing: 6) {
                    Image(systemName: after < before ? "arrow.down.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(after < before ? .green : .orange)
                    Text("\(result.pages) pages · \(bytes(before)) → \(bytes(after))\(before > 0 ? " (\(Int((Double(after) / Double(before) - 1) * 100))%)" : "")")
                }
                .font(.callout)
                if after >= before, before > 0 {
                    Text("The optimised copy is larger than the original; keeping the original is probably better.").font(.caption).foregroundStyle(.orange)
                }
            }
            HStack {
                if sent { Label("Sent to your reMarkable", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if let result {
                    Button("Save PDF…") { save(result.pdf) }
                    Button("Send to reMarkable") { Task { await send(result.pdf) } }.keyboardShortcut(.defaultAction).disabled(sent)
                } else {
                    Button("Convert") { Task { await convert() } }.keyboardShortcut(.defaultAction).disabled(progress != nil)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { if case .document(let d) = source { folder = d.parent } }
    }

    private func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    private func convert() async {
        error = nil
        progress = (0, 1)
        do {
            let url = try await inputFile()
            let options = Converter.Options(quality: quality, device: device, splitSpreads: split, mangaOrder: manga)
            result = try await Task.detached(priority: .userInitiated) {
                try Converter.convert(url, options: options) { done, total in
                    Task { @MainActor in self.progress = (done, total) }
                }
            }.value
        } catch {
            self.error = error.localizedDescription
            progress = nil
        }
    }

    /// The source as a local file (library documents are downloaded first).
    private func inputFile() async throws -> URL {
        switch source {
        case .file(let u): return u
        case .document(let d):
            guard let hash = d.payloadHash else { throw RMError.notFound("Only PDFs and EPUBs can be converted") }
            let data = try await model.sync.blob(hash, filename: "\(d.id).\(d.kind == .epub ? "epub" : "pdf")")
            let url = FileManager.default.temporaryDirectory.appending(path: "\(d.id).\(d.kind == .epub ? "epub" : "pdf")")
            try data.write(to: url)
            return url
        }
    }

    private func send(_ pdf: Data) async {
        do {
            _ = try await model.sync.upload(data: pdf, filename: "\(source.name) (\(device == .rm2 || device == .rm1 ? "RM2" : "Paper Pro")).pdf", parentID: folder)
            sent = true
            model.addLog("Sent an optimised copy of \(source.name) to your reMarkable.")
            await model.syncNow(quiet: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ pdf: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(source.name) (optimised).pdf"
        if panel.runModal() == .OK, let url = panel.url { try? pdf.write(to: url) }
    }
}
