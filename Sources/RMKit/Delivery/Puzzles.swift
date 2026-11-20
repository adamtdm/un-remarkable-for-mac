import CoreGraphics
import Foundation
import PDFKit

/// Daily puzzles, ported from the web app's `DailyPuzzlesGenerator`: Guardian crosswords and a sudoku.
public enum DailyPuzzles {
    static let userAgent = "Un-remarkable-Mac (reMarkable companion)"

    /// Fetches a Guardian crossword PDF ("quick" or "cryptic") and trims its margins. Falls back up to four
    /// days when none was published today (e.g. Sundays). Returns the PDF and a filename.
    public static func guardianCrossword(_ type: String, date: Date = .now, session: URLSession = .shared) async throws -> (Data, String) {
        let cal = Calendar(identifier: .gregorian)
        for back in 0..<5 {
            guard let day = cal.date(byAdding: .day, value: -back, to: date) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let stamp = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
            var req = URLRequest(url: URL(string: "https://crosswords-static.guim.co.uk/gdn.\(type).\(stamp).pdf")!, timeoutInterval: 15)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 else { continue }
            let name = "Guardian_\(type == "quick" ? "Quick" : "Cryptic")_Crossword_\(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)).pdf"
            return (cropToContent(data, margin: 16) ?? data, name)
        }
        throw RMError.notFound("Couldn't find a recent Guardian \(type) crossword")
    }

    /// Sets each page's crop box to its content (plus a margin) so the puzzle fills the tablet screen.
    public static func cropToContent(_ pdf: Data, margin: CGFloat) -> Data? {
        guard let doc = PDFDocument(data: pdf) else { return nil }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            guard box.width > 0, box.height > 0 else { continue }
            let scale = 400 / max(box.width, box.height)
            let w = Int(box.width * scale), h = Int(box.height * scale)
            var px = [UInt8](repeating: 255, count: w * h)
            guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: ctx)
            var minX = w, maxX = -1, minY = h, maxY = -1
            for y in 0..<h { for x in 0..<w where px[y * w + x] < 245 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            guard maxX >= minX, maxY >= minY else { continue }
            // Bitmap rows run top-down; PDF space runs bottom-up.
            let content = CGRect(x: box.minX + CGFloat(minX) / scale, y: box.minY + CGFloat(h - 1 - maxY) / scale,
                                 width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
            page.setBounds(content.insetBy(dx: -margin, dy: -margin).intersection(box), for: .cropBox)
        }
        return doc.dataRepresentation()
    }

    /// A two-page sudoku PDF: puzzle, then solution. The date seeds the puzzle.
    public static func sudoku(difficulty: String, date: Date = .now, device: DeviceProfile = .current) -> (Data, String) {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let clues = Sudoku.clues(for: difficulty)
        let (puzzle, solution) = Sudoku.generate(seed: UInt64(c.year! * 10_000 + c.month! * 100 + c.day!), clues: clues)
        let size = device.portrait
        let canvas = PDFCanvas(width: size.width, height: size.height)
        let long = date.formatted(.dateTime.weekday(.wide).month(.wide).day(.twoDigits).year())
        let given = puzzle.joined().filter { $0 != 0 }.count
        page(canvas, grid: puzzle, title: "DAILY SUDOKU", subtitle: "\(long)   |   Difficulty: \(difficulty.capitalized)   |   \(given) Clues", solution: false)
        page(canvas, grid: solution, title: "DAILY SUDOKU - SOLUTION", subtitle: "\(long)   |   Difficulty: \(difficulty.capitalized) Solution", solution: true)
        return (canvas.finish(), "Daily_Sudoku_\(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)).pdf")
    }

    static func page(_ p: PDFCanvas, grid: Sudoku.Grid, title: String, subtitle: String, solution: Bool) {
        p.beginPage()
        let w = p.width, h = p.height
        let s = w / 1620 // layout designed for the Paper Pro's 1620-wide page
        p.line(90 * s, 90 * s, w - 90 * s, 90 * s, width: 3)
        p.text(title, x: 90 * s, y: 160 * s, size: 42 * s)
        p.line(90 * s, 185 * s, w - 90 * s, 185 * s)
        p.text(subtitle, x: 90 * s, y: 225 * s, size: 20 * s)
        p.line(90 * s, 250 * s, w - 90 * s, 250 * s)

        let cell = 135 * s, side = cell * 9
        let x0 = (w - side) / 2, y0 = 340 * s
        for i in 0...9 {
            let lw: CGFloat = i % 3 == 0 ? 4.5 : 1.5
            p.line(x0, y0 + CGFloat(i) * cell, x0 + side, y0 + CGFloat(i) * cell, width: lw)
            p.line(x0 + CGFloat(i) * cell, y0, x0 + CGFloat(i) * cell, y0 + side, width: lw)
        }
        for r in 0..<9 { for c in 0..<9 where grid[r][c] != 0 {
            let digit = String(grid[r][c])
            let face: PDFCanvas.Face = solution ? .sans : .serifBold
            let tw = PDFCanvas.textWidth(digit, face: face, size: 56 * s)
            p.text(digit, x: x0 + CGFloat(c) * cell + (cell - tw) / 2, y: y0 + CGFloat(r) * cell + cell * 0.72, face: face, size: 56 * s)
        } }
        if !solution {
            let notes = y0 + side + 80 * s
            p.line(90 * s, notes, w - 90 * s, notes, gray: 0.4)
            p.text("SCRATCHPAD & PENCIL MARKS", x: 90 * s, y: notes + 35 * s, size: 16 * s, gray: 0.3)
            var y = notes + 70 * s
            while y < h - 120 * s {
                p.line(90 * s, y, w - 90 * s, y, width: 0.5, gray: 0.7)
                y += 60 * s
            }
        }
        p.text(solution ? "Un-remarkable Puzzles Edition" : "Un-remarkable Puzzles Edition   •   Solution on next page",
               x: 90 * s, y: h - 60 * s, size: 15 * s, gray: 0.4)
    }
}
