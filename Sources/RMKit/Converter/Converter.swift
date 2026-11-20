import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// The web/Android "reMarkable Document & Comic Converter": turns heavy PDFs, CBZ comics and fixed-layout
/// (image) EPUBs into lean single-layer PDFs sized for the tablet's screen.
public enum Converter {
    public struct Options: Sendable, Equatable {
        public var quality = 3
        public var device = DeviceProfile.paperPro
        /// Split landscape double-page spreads into two pages.
        public var splitSpreads = true
        /// Right-to-left (manga): the right half of a spread comes first.
        public var mangaOrder = false
        public init(quality: Int = 3, device: DeviceProfile = .paperPro, splitSpreads: Bool = true, mangaOrder: Bool = false) {
            self.quality = quality
            self.device = device
            self.splitSpreads = splitSpreads
            self.mangaOrder = mangaOrder
        }
    }

    public struct Result: Sendable {
        public let pdf: Data
        public let pages: Int
        public let inputBytes: Int
    }

    public typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void

    /// Converts a file by type (pdf, cbz/zip, epub).
    public static func convert(_ url: URL, options: Options, progress: Progress = { _, _ in }) throws -> Result {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { throw RMError.malformed("Not a readable PDF") }
            return try convert(pdf: doc, options: options, inputBytes: size, progress: progress)
        case "cbz", "zip", "epub":
            let dir = FileManager.default.temporaryDirectory.appending(path: "convert-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            try unzip(url, to: dir)
            let images = url.pathExtension.lowercased() == "epub" ? try epubImages(dir) : comicImages(dir)
            guard !images.isEmpty else { throw RMError.malformed("No page images found\(url.pathExtension.lowercased() == "epub" ? " (only image-based EPUBs can be converted)" : "")") }
            return try convert(images: images, options: options, inputBytes: size, progress: progress)
        default:
            throw RMError.malformed("Can't convert .\(url.pathExtension) files; use PDF, CBZ or EPUB")
        }
    }

    public static func convert(pdf: PDFDocument, options: Options, inputBytes: Int = 0, progress: Progress = { _, _ in }) throws -> Result {
        let target = targetSize(options)
        var writer = PDFImageWriter()
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            autoreleasepool {
                if let image = render(page, longEdge: max(target.width, target.height) * 2) {
                    for part in parts(image, options) { writer.add(encode(part, target: target, options: options)) }
                }
            }
            progress(i + 1, pdf.pageCount)
        }
        return Result(pdf: writer.finish(), pages: writer.count, inputBytes: inputBytes)
    }

    public static func convert(images: [URL], options: Options, inputBytes: Int = 0, progress: Progress = { _, _ in }) throws -> Result {
        let target = targetSize(options)
        var writer = PDFImageWriter()
        for (i, url) in images.enumerated() {
            autoreleasepool {
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    for part in parts(image, options) { writer.add(encode(part, target: target, options: options)) }
                }
            }
            progress(i + 1, images.count)
        }
        return Result(pdf: writer.finish(), pages: writer.count, inputBytes: inputBytes)
    }

    /// Portrait target: the quality stop's size (defined for the Paper Pro's 1620×2160 screen) scaled to
    /// the device's screen, so stop 3 is a 1:1 pixel match on every model.
    static func targetSize(_ o: Options) -> (width: Int, height: Int) {
        let q = QualityProfile.stop(o.quality)
        let factor = Double(o.device.portrait.height) / 2160
        return (Int((Double(q.maxWidth) * factor).rounded()), Int((Double(q.maxHeight) * factor).rounded()))
    }

    static func isSpread(_ image: CGImage) -> Bool { Double(image.width) > Double(image.height) * 1.15 }

    /// One page, or a spread's two halves in reading order.
    static func parts(_ image: CGImage, _ o: Options) -> [CGImage] {
        guard o.splitSpreads, isSpread(image) else { return [image] }
        let half = image.width / 2
        guard let left = image.cropping(to: CGRect(x: 0, y: 0, width: half, height: image.height)),
              let right = image.cropping(to: CGRect(x: half, y: 0, width: image.width - half, height: image.height)) else { return [image] }
        return o.mangaOrder ? [right, left] : [left, right]
    }

    /// Scales to fit the target (never up), converts to grayscale for monochrome tablets and JPEG-encodes.
    static func encode(_ image: CGImage, target: (width: Int, height: Int), options: Options) -> (jpeg: Data, width: Int, height: Int) {
        let landscape = image.width > image.height
        let maxW = landscape ? target.height : target.width
        let maxH = landscape ? target.width : target.height
        let scale = min(Double(maxW) / Double(image.width), Double(maxH) / Double(image.height), 1)
        let w = max(Int(Double(image.width) * scale), 1), h = max(Int(Double(image.height) * scale), 1)
        let gray = !options.device.isColor
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let scaled = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: QualityProfile.stop(options.quality).jpegQuality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return (data as Data, w, h)
    }

    static func render(_ page: PDFPage, longEdge: Int) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let pw = rotated ? box.height : box.width, ph = rotated ? box.width : box.height
        guard pw > 0, ph > 0 else { return nil }
        let scale = min(CGFloat(longEdge) / max(pw, ph), 4)
        let w = Int(pw * scale), h = Int(ph * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    // MARK: Archives

    static func unzip(_ url: URL, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", url.path, dir.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw RMError.malformed("Couldn't open the archive") }
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff", "heic"]

    /// Comic pages in natural order ("page2" before "page10"), skipping macOS metadata.
    static func comicImages(_ dir: URL) -> [URL] {
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { imageExtensions.contains($0.pathExtension.lowercased()) && !$0.path.contains("__MACOSX") && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Images of a fixed-layout EPUB in spine order: the first image each spine page shows.
    static func epubImages(_ dir: URL) throws -> [URL] {
        let container = try XMLDocument(contentsOf: dir.appending(path: "META-INF/container.xml"))
        guard let opfPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else { return [] }
        let opfURL = dir.appending(path: opfPath)
        let opf = try XMLDocument(contentsOf: opfURL)
        let base = opfURL.deletingLastPathComponent()
        var manifest: [String: String] = [:]
        for case let item as XMLElement in try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            if let id = item.attribute(forName: "id")?.stringValue, let href = item.attribute(forName: "href")?.stringValue { manifest[id] = href }
        }
        var out: [URL] = []
        for case let ref as XMLElement in try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']") {
            guard let idref = ref.attribute(forName: "idref")?.stringValue, let href = manifest[idref] else { continue }
            let page = base.appending(path: href.removingPercentEncoding ?? href).standardizedFileURL
            if imageExtensions.contains(page.pathExtension.lowercased()) { out.append(page); continue }
            guard let html = try? String(contentsOf: page, encoding: .utf8),
                  let m = html.firstMatch(of: /(?:<img[^>]+src|<image[^>]+(?:xlink:)?href)\s*=\s*["']([^"']+)["']/) else { continue }
            let src = String(m.1)
            out.append(page.deletingLastPathComponent().appending(path: src.removingPercentEncoding ?? src).standardizedFileURL)
        }
        return out.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Writes JPEG pages into a PDF without re-encoding them (Quartz keeps JPEG-backed images as DCT streams).
struct PDFImageWriter {
    private let data = NSMutableData()
    private var ctx: CGContext?
    private(set) var count = 0

    mutating func add(_ page: (jpeg: Data, width: Int, height: Int)) {
        if ctx == nil {
            ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: nil, nil)
        }
        guard let ctx, let provider = CGDataProvider(data: page.jpeg as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        // 1 px = 1 pt keeps the page aspect exact; the tablet fits it to the screen.
        var box = CGRect(x: 0, y: 0, width: page.width, height: page.height)
        ctx.beginPage(mediaBox: &box)
        ctx.draw(image, in: box)
        ctx.endPage()
        count += 1
    }

    mutating func finish() -> Data {
        ctx?.closePDF()
        return data as Data
    }
}
