import AppKit
import PDFKit
import RMKit

struct OutlineItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let pageIndex: Int
    let depth: Int
}

struct HighlightItem: Identifiable, Hashable {
    let id = UUID()
    let pageIndex: Int
    let text: String
    let color: Color
    enum Color: Hashable { case pen(Int), rgb(UInt8, UInt8, UInt8) }
}

final class ImageBox: @unchecked Sendable {
    let image: CGImage
    let invertedPDF: Bool
    init(_ image: CGImage, invertedPDF: Bool = false) {
        self.image = image
        self.invertedPDF = invertedPDF
    }
}

/// Loads document payloads on demand and renders pages and thumbnails off the main thread.
actor DocumentRenderer {
    let sync: SyncEngine
    let thumbnailDir: URL
    private var pdfs: [String: PDFDocument] = [:] // keyed by payload hash
    private let cache = NSCache<NSString, ImageBox>()

    init(sync: SyncEngine, thumbnails: URL) {
        self.sync = sync
        self.thumbnailDir = thumbnails
        cache.totalCostLimit = 512 * 1024 * 1024
    }

    // MARK: Payloads

    /// Ensures the PDF payload is local and returns it. Large books download once and stay cached.
    func pdf(for doc: DocumentItem) async throws -> PDFDocument? {
        guard doc.kind == .pdf, let hash = doc.payloadHash else { return nil }
        if let p = pdfs[hash] { return p }
        _ = try await sync.blob(hash, filename: "\(doc.id).pdf")
        guard let p = PDFDocument(url: sync.blobs.url(for: hash)) else { return nil }
        if pdfs.count > 6 { pdfs.removeAll() }
        pdfs[hash] = p
        return p
    }

    func isPayloadCached(_ doc: DocumentItem) -> Bool {
        guard let h = doc.payloadHash else { return true }
        return sync.blobs.has(h)
    }

    func rmPage(_ doc: DocumentItem, _ index: Int) async -> RmPage? {
        guard let rm = doc.rmFile(for: index), let data = try? await sync.blob(rm.hash, filename: rm.name) else { return nil }
        return RmParser.parse(data)
    }

    func pageCount(_ doc: DocumentItem) async -> Int {
        if doc.kind == .pdf, doc.pages.isEmpty, let p = try? await pdf(for: doc) { return max(p.pageCount, 1) }
        return doc.displayPageCount
    }

    // MARK: Export

    /// The document as a vector PDF with its ink (see `AnnotatedPDF`).
    func annotatedPDF(_ doc: DocumentItem) async throws -> Data {
        let pdf = doc.kind == .pdf ? try await self.pdf(for: doc) : nil
        let count = await pageCount(doc)
        var pages: [AnnotatedPDF.Page] = []
        for i in 0..<count {
            let index = doc.pdfPageIndex(for: i)
            pages.append(AnnotatedPDF.Page(pdf: index >= 0 ? pdf?.page(at: index) : nil, ink: await rmPage(doc, i)))
        }
        return AnnotatedPDF.make(pages)
    }

    // MARK: Pages

    func page(_ doc: DocumentItem, index: Int, options: RenderOptions) async throws -> ImageBox? {
        let key = "\(doc.hash)|\(index)|\(options.dark)|\(String(describing: options.invertPDF))|\(options.pixelWidth)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let overlay = await rmPage(doc, index)
        var box: ImageBox?
        if doc.kind == .pdf, let pdf = try await pdf(for: doc) {
            let pdfIndex = doc.pdfPageIndex(for: index)
            if pdfIndex >= 0, let p = pdf.page(at: pdfIndex),
               let r = PageRenderer.renderPDF(p, overlay: overlay, options: options) {
                box = ImageBox(r.image, invertedPDF: r.inverted)
            }
        }
        if box == nil, let img = PageRenderer.renderNotebook(overlay, options: options) {
            box = ImageBox(img)
        }
        if let box { cache.setObject(box, forKey: key, cost: box.image.bytesPerRow * box.image.height) }
        return box
    }

    /// Warms the cache for neighbouring pages.
    func prefetch(_ doc: DocumentItem, around index: Int, count: Int, options: RenderOptions) async {
        for i in [index + 1, index + 2, index - 1] where i >= 0 && i < count {
            _ = try? await page(doc, index: i, options: options)
        }
    }

    // MARK: Thumbnails

    func thumbnail(_ doc: DocumentItem, dark: Bool) async -> CGImage? {
        let file = thumbnailDir.appending(path: "\(doc.id)-\(doc.hash.prefix(16))-\(dark ? "d" : "l").png")
        if let src = CGImageSourceCreateWithURL(file as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return img
        }
        var image: CGImage?
        switch doc.kind {
        case .notebook:
            image = try? await page(doc, index: 0, options: RenderOptions(dark: dark, pixelWidth: 360))?.image
        case .pdf:
            if isPayloadCached(doc) {
                image = try? await page(doc, index: 0, options: RenderOptions(dark: dark, invertPDF: false, pixelWidth: 360))?.image
            } else {
                image = await cloudThumbnail(doc)
                // Like the web app, fetch the file to draw its cover (short PDFs only, not whole comics).
                if image == nil, Self.coverDownloads, doc.displayPageCount <= 60 {
                    image = try? await page(doc, index: 0, options: RenderOptions(dark: dark, invertPDF: false, pixelWidth: 360))?.image
                }
            }
        case .epub:
            image = await cloudThumbnail(doc)
            if image == nil, Self.coverDownloads || doc.payloadHash.map(sync.blobs.has) == true { image = await epubCover(doc) }
        case .folder:
            return nil
        }
        if let image { writePNG(image, to: file) }
        return image
    }

    static var coverDownloads: Bool { UserDefaults.standard.object(forKey: "coverDownloads") as? Bool ?? true }

    private func epubCover(_ doc: DocumentItem) async -> CGImage? {
        let cache = thumbnailDir.deletingLastPathComponent().appending(path: "epub")
        guard let book = try? await EpubBook.load(doc, sync: sync, cacheDir: cache),
              let url = EpubBook.coverImage(root: book.root),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                             kCGImageSourceThumbnailMaxPixelSize: 480] as CFDictionary)
    }

    /// Some documents carry tablet-made thumbnails (`<id>.thumbnails/<page>.png`).
    private func cloudThumbnail(_ doc: DocumentItem) async -> CGImage? {
        let firstPage = doc.pages.first?.pageID
        let entry = doc.subfiles.first { $0.key.contains(".thumbnails/") && (firstPage == nil || $0.key.contains(firstPage!)) }
            ?? doc.subfiles.first { $0.key.contains(".thumbnails/") }
        guard let entry, let data = try? await sync.blob(entry.value, filename: entry.key),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    func clearThumbnails() {
        try? FileManager.default.removeItem(at: thumbnailDir)
        try? FileManager.default.createDirectory(at: thumbnailDir, withIntermediateDirectories: true)
        cache.removeAllObjects()
    }

    // MARK: Navigation aids

    func outline(_ doc: DocumentItem) async -> [OutlineItem] {
        guard let pdf = try? await pdf(for: doc), let root = pdf.outlineRoot else { return [] }
        // Map PDF page → logical page (inserted note pages shift numbering).
        var logical: [Int: Int] = [:]
        for i in 0..<max(doc.pages.count, pdf.pageCount) {
            let p = doc.pdfPageIndex(for: i)
            if p >= 0, logical[p] == nil { logical[p] = i }
        }
        var out: [OutlineItem] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let c = node.child(at: i) else { continue }
                if let page = c.destination?.page {
                    let idx = pdf.index(for: page)
                    out.append(OutlineItem(title: c.label ?? "Untitled", pageIndex: logical[idx] ?? idx, depth: depth))
                }
                walk(c, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return out
    }

    /// All smart highlights in the document, in page order.
    func highlights(_ doc: DocumentItem) async -> [HighlightItem] {
        var out: [HighlightItem] = []
        for i in 0..<doc.displayPageCount {
            guard let page = await rmPage(doc, i) else { continue }
            for h in page.highlights where !h.text.trimmingCharacters(in: .whitespaces).isEmpty {
                let color: HighlightItem.Color = h.explicitColor.map { .rgb($0.r, $0.g, $0.b) } ?? .pen(h.color.rawValue)
                out.append(HighlightItem(pageIndex: i, text: h.text, color: color))
            }
        }
        return out
    }
}
