import Foundation

/// Parser for reMarkable `.rm` page files: firmware v6 CRDT scene blocks and legacy v3/v5 line files.
/// Ported from the Android app's `RmBinaryParser`, which mirrors rmscene.
public enum RmParser {
    static let headerLength = 43
    static let textTopY: Float = -88
    static let anchorTop = CrdtID(0, 281_474_976_710_654)
    static let anchorBottom = CrdtID(0, 281_474_976_710_655)

    public static func parse(_ data: Data) -> RmPage? {
        guard data.count >= headerLength else { return nil }
        let header = String(decoding: data.prefix(headerLength), as: UTF8.self)
        let bytes = [UInt8](data)
        if header.hasPrefix("reMarkable .lines file, version=6") { return parseV6(bytes) }
        if header.hasPrefix("reMarkable .lines file, version=5") { return parseLegacy(bytes, v5: true) }
        if header.hasPrefix("reMarkable .lines file, version=3") { return parseLegacy(bytes, v5: false) }
        return nil
    }

    // MARK: Legacy v3/v5

    static func parseLegacy(_ bytes: [UInt8], v5: Bool) -> RmPage? {
        var r = ByteReader(bytes, pos: headerLength)
        do {
            var page = RmPage()
            let numLayers = min(max(Int(try r.u32()), 0), 64)
            for l in 0..<numLayers {
                let numStrokes = min(Int(try r.u32()), 100_000)
                var strokes: [Stroke] = []
                for _ in 0..<numStrokes {
                    let pen = Int(try r.u32()), color = Int(try r.u32())
                    _ = try r.u32()
                    let width = try r.f32()
                    if v5 { _ = try r.u32() }
                    let n = min(Int(try r.u32()), 200_000)
                    var pts: [StrokePoint] = []
                    pts.reserveCapacity(n)
                    for _ in 0..<n {
                        let x = try r.f32(), y = try r.f32(), speed = try r.f32(), dir = try r.f32(), w = try r.f32(), p = try r.f32()
                        pts.append(StrokePoint(x: x, y: y, speed: speed, direction: dir, width: w, pressure: min(max(p, 0), 1)))
                    }
                    if !pts.isEmpty {
                        strokes.append(Stroke(tool: ToolType(raw: pen), color: PenColor(raw: color), thicknessScale: width, points: pts))
                    }
                }
                page.layers.append(Layer(name: "Layer \(l + 1)", strokes: strokes))
            }
            return page
        } catch {
            return nil
        }
    }

    // MARK: v6

    final class GroupNode {
        let id: CrdtID
        var label = ""
        var visible = true
        var anchorID: CrdtID?
        var anchorOriginX: Float = 0
        var items: [SeqItem] = []
        init(_ id: CrdtID) { self.id = id }
    }

    enum Value {
        case stroke(Stroke)
        case group(GroupNode)
        case text(String)
        case format(Int)
    }

    struct SeqItem {
        var id: CrdtID
        var left: CrdtID
        var right: CrdtID
        var deletedLength: Int
        var value: Value
    }

    static func parseV6(_ bytes: [UInt8]) -> RmPage? {
        var r = ByteReader(bytes, pos: headerLength)
        var paperSize: (Int, Int)?
        var groups: [CrdtID: GroupNode] = [:]
        var groupOrder: [CrdtID] = []
        func group(_ id: CrdtID) -> GroupNode {
            if let g = groups[id] { return g }
            let g = GroupNode(id)
            groups[id] = g
            groupOrder.append(id)
            return g
        }

        var highlights: [HighlightRect] = []
        var textItems: [SeqItem] = []
        var textStyles: [CrdtID: ParagraphStyle] = [:]
        var textPosX: Float = -468, textPosY: Float = 234, textWidth: Float = 936

        while r.pos + 8 <= bytes.count {
            guard let blockLen = try? Int(r.u32()), blockLen >= 0, r.pos + 4 + blockLen <= bytes.count else { break }
            _ = try? r.u8() // unknown
            _ = try? r.u8() // min version
            let version = (try? r.u8()) ?? 0
            let blockType = (try? r.u8()) ?? 0
            let blockEnd = r.pos + blockLen
            r.limit = blockEnd

            do {
                switch blockType {
                case 0x0D: // SceneInfo
                    while r.pos < blockEnd {
                        let (idx, type) = try r.tagHeader()
                        if idx == 5, type == Tag.length4 {
                            let end = try r.enterLength4()
                            if r.pos + 8 <= end {
                                let w = Int(try r.u32()), h = Int(try r.u32())
                                if w > 0, h > 0 { paperSize = (w, h) }
                            }
                            r.pos = end
                        } else {
                            try r.skip(type, limit: blockEnd)
                        }
                    }

                case 0x01: // SceneTree: links a child group under its parent
                    let treeID = try r.id(1)
                    _ = try r.id(2)
                    _ = try r.bool(3)
                    let end = try r.subblock(4)
                    let parentID = try r.id(1)
                    r.pos = end
                    group(parentID).items.append(SeqItem(id: treeID, left: .end, right: .end, deletedLength: 0, value: .group(group(treeID))))

                case 0x02: // TreeNode: label, visibility, text anchor
                    let node = group(try r.id(1))
                    while r.pos < blockEnd {
                        let (idx, type) = try r.tagHeader()
                        switch (idx, type) {
                        case (2, Tag.length4): node.label = try r.lwwString()
                        case (3, Tag.length4): node.visible = try r.lwwBool()
                        case (7, Tag.length4): node.anchorID = try r.lwwID()
                        case (10, Tag.length4): node.anchorOriginX = try r.lwwFloat()
                        default: try r.skip(type, limit: blockEnd)
                        }
                    }

                case 0x04: // SceneGroupItem: ordered reference to a child group
                    let parentID = try r.id(1), itemID = try r.id(2), left = try r.id(3), right = try r.id(4)
                    let del = Int(try r.int(5))
                    if del == 0, r.hasSubblock(6) {
                        let end = try r.subblock(6)
                        if try r.u8() == 0x02 {
                            let target = try r.id(2)
                            group(parentID).items.append(SeqItem(id: itemID, left: left, right: right, deletedLength: 0, value: .group(group(target))))
                        }
                        r.pos = end
                    }

                case 0x05: // SceneLineItem: a pen stroke
                    let parentID = try r.id(1), itemID = try r.id(2), left = try r.id(3), right = try r.id(4)
                    let del = Int(try r.int(5))
                    if del == 0, r.hasSubblock(6) {
                        let end = try r.subblock(6)
                        if try r.u8() == 0x03, let stroke = try readLine(&r, version: Int(version), end: end) {
                            group(parentID).items.append(SeqItem(id: itemID, left: left, right: right, deletedLength: 0, value: .stroke(stroke)))
                        }
                        r.pos = end
                    }

                case 0x03: // SceneGlyphItem: PDF text highlights
                    for i in 1...4 { _ = try r.id(i) }
                    let del = Int(try r.int(5))
                    if del == 0, r.hasSubblock(6) {
                        let end = try r.subblock(6)
                        if try r.u8() == 0x01 {
                            _ = r.optionalInt(2, limit: end)
                            _ = r.optionalInt(3, limit: end)
                            let colorID = Int(try r.int(4))
                            let text = try r.string(5)
                            let rectsEnd = try r.subblock(6)
                            let n = min(Int(try r.varuint()), 10_000)
                            var rects: [[Float]] = []
                            for _ in 0..<n where r.pos + 32 <= rectsEnd {
                                rects.append([Float(try r.f64()), Float(try r.f64()), Float(try r.f64()), Float(try r.f64())])
                            }
                            r.pos = rectsEnd
                            let explicit = r.optionalInt(10, limit: end).map { Rgba(argb: $0) }
                            for (i, rc) in rects.enumerated() {
                                // The text belongs to the whole highlight; attach it to the first rect only.
                                highlights.append(HighlightRect(x: rc[0], y: rc[1], w: rc[2], h: rc[3], color: PenColor(raw: colorID),
                                                                explicitColor: explicit, text: i == 0 ? text : ""))
                            }
                        }
                        r.pos = end
                    }

                case 0x07: // RootText: CRDT typed text and paragraph styles
                    _ = try r.id(1)
                    let sub2 = try r.subblock(2)
                    let sub21 = try r.subblock(1)
                    let sub211 = try r.subblock(1)
                    let n = min(Int(try r.varuint()), 100_000)
                    var items: [SeqItem] = []
                    for _ in 0..<n where r.pos < sub211 {
                        let itemEnd = try r.subblock(0)
                        let id = try r.id(2), left = try r.id(3), right = try r.id(4)
                        let del = Int(try r.int(5))
                        var value = Value.text("")
                        if r.hasSubblock(6, limit: itemEnd) {
                            let strEnd = try r.subblock(6)
                            let len = Int(try r.varuint())
                            _ = try r.u8() // is-ascii flag
                            let s = String(decoding: try r.bytes(min(len, strEnd - r.pos)), as: UTF8.self)
                            if let fmt = r.optionalInt(2, limit: strEnd), s.isEmpty { value = .format(Int(fmt)) } else { value = .text(s) }
                            r.pos = strEnd
                        }
                        r.pos = itemEnd
                        items.append(SeqItem(id: id, left: left, right: right, deletedLength: del, value: value))
                    }
                    r.pos = sub211
                    r.pos = sub21

                    if r.hasSubblock(2, limit: sub2) {
                        let sub22 = try r.subblock(2)
                        let sub221 = try r.subblock(1)
                        let nf = min(Int(try r.varuint()), 50_000)
                        for _ in 0..<nf where r.pos < sub221 {
                            let charID = try r.rawID()
                            _ = try r.id(1)
                            let fmtEnd = try r.subblock(2)
                            _ = try r.u8() // 17 marker
                            let code = Int(try r.u8())
                            r.pos = fmtEnd
                            textStyles[charID] = ParagraphStyle(code: code)
                        }
                        r.pos = sub221
                        r.pos = sub22
                    }
                    r.pos = sub2
                    if r.hasSubblock(3) {
                        let end = try r.subblock(3)
                        textPosX = Float(try r.f64())
                        textPosY = Float(try r.f64())
                        r.pos = end
                    }
                    if r.pos < blockEnd, let w = r.optionalFloat(4, limit: blockEnd) { textWidth = w }
                    textItems = items

                default:
                    break
                }
            } catch {
                // Malformed block: skip it using its framing length.
            }
            r.pos = blockEnd
            r.limit = bytes.count
        }

        let (paragraphs, anchors) = buildParagraphs(textItems, styles: textStyles, textPosX: textPosX, textPosY: textPosY,
                                                    textWidth: textWidth, defaultHeight: paperSize?.1 ?? RmPage.rm2Size.height)

        var layers: [Layer] = []
        var visited = Set<CrdtID>()

        func collect(_ g: GroupNode, ax: Float, ay: Float, into out: inout [Stroke]) {
            guard visited.insert(g.id).inserted, g.visible else { return }
            let gx = g.anchorID != nil ? g.anchorOriginX : 0
            let gy = g.anchorID.flatMap { anchors[$0] } ?? 0
            let tx = ax + gx, ty = ay + gy
            var seenChildren = Set<CrdtID>()
            for v in toposortValues(g.items) {
                switch v {
                case .stroke(var s):
                    if tx != 0 || ty != 0 {
                        s.points = s.points.map { var p = $0; p.x += tx; p.y += ty; return p }
                    }
                    out.append(s)
                case .group(let child):
                    if seenChildren.insert(child.id).inserted { collect(child, ax: tx, ay: ty, into: &out) }
                default: break
                }
            }
        }

        if let rootGroup = groups[CrdtID(0, 1)] {
            visited.insert(rootGroup.id)
            var direct: [Stroke] = []
            var seenLayers = Set<CrdtID>()
            for child in toposortValues(rootGroup.items) {
                switch child {
                case .group(let g) where g.visible && seenLayers.insert(g.id).inserted:
                    var strokes: [Stroke] = []
                    collect(g, ax: 0, ay: 0, into: &strokes)
                    if !strokes.isEmpty { layers.append(Layer(name: g.label.isEmpty ? "Layer \(layers.count + 1)" : g.label, strokes: strokes)) }
                case .stroke(let s): direct.append(s)
                default: break
                }
            }
            if !direct.isEmpty { layers.insert(Layer(name: "Layer 1", strokes: direct), at: 0) }
        }
        for id in groupOrder {
            guard let g = groups[id], !visited.contains(id), g.visible else { continue }
            var extra: [Stroke] = []
            collect(g, ax: 0, ay: 0, into: &extra)
            if !extra.isEmpty { layers.append(Layer(name: g.label.isEmpty ? "Layer \(layers.count + 1)" : g.label, strokes: extra)) }
        }

        // SceneInfo is optional, and files written by other tools may declare the reMarkable 2 size even
        // when they were then written on with a Paper Pro. Ink outside the RM2 frame means a Paper Pro page.
        let exceedsRM2 = layers.contains { $0.strokes.contains { $0.points.contains { abs($0.x) > 706 || $0.y > 1880 } } }
        let size: (Int, Int)
        if let paperSize, !(exceedsRM2 && paperSize.0 <= RmPage.rm2Size.width) {
            size = paperSize
        } else {
            size = exceedsRM2 ? (RmPage.paperProSize.width, RmPage.paperProSize.height) : (RmPage.rm2Size.width, RmPage.rm2Size.height)
        }

        return RmPage(width: size.0, height: size.1, layers: layers, centerOriginX: true, highlights: highlights,
                      paragraphs: paragraphs, textPosX: textPosX, textPosY: textPosY, textWidth: textWidth)
    }

    static func readLine(_ r: inout ByteReader, version: Int, end: Int) throws -> Stroke? {
        let tool = Int(try r.int(1))
        let color = Int(try r.int(2))
        let thickness = Float(try r.double(3))
        _ = try r.float(4) // starting length
        let ptsEnd = try r.subblock(5)
        let pointSize = version == 1 ? 24 : 14
        let n = max(ptsEnd - r.pos, 0) / pointSize
        var pts: [StrokePoint] = []
        pts.reserveCapacity(n)
        for _ in 0..<n {
            let x = try r.f32(), y = try r.f32()
            if version == 1 {
                let speed = try r.f32() * 4
                let dir = Float(255 * Double(try r.f32()) / (2 * .pi))
                let w = try r.f32() * 4
                let p = min(max(try r.f32(), 0), 1)
                pts.append(StrokePoint(x: x, y: y, speed: speed, direction: dir, width: w, pressure: p))
            } else {
                let speed = Float(try r.u16()), w = Float(try r.u16()), dir = Float(try r.u8())
                let p = Float(try r.u8()) / 255
                pts.append(StrokePoint(x: x, y: y, speed: speed, direction: dir, width: w, pressure: p))
            }
        }
        r.pos = ptsEnd
        var explicit: Rgba?
        while r.pos < end {
            let (idx, type) = try r.tagHeader()
            if idx == 8, type == Tag.byte4 { explicit = Rgba(argb: try r.u32()) } else { try r.skip(type, limit: end) }
        }
        guard !pts.isEmpty else { return nil }
        return Stroke(tool: ToolType(raw: tool), color: PenColor(raw: color), thicknessScale: thickness, points: pts, explicitColor: explicit)
    }

    // MARK: Typed text

    static func buildParagraphs(_ raw: [SeqItem], styles: [CrdtID: ParagraphStyle], textPosX: Float = -468, textPosY: Float,
                                textWidth: Float = 936, defaultHeight: Int) -> ([TypedParagraph], [CrdtID: Float]) {
        var anchors: [CrdtID: Float] = [:]
        guard !raw.isEmpty else {
            anchors[anchorTop] = 0
            anchors[anchorBottom] = Float(defaultHeight)
            return ([], anchors)
        }

        let expanded = expand(raw)
        let order = toposortIDs(expanded)
        var byID: [CrdtID: SeqItem] = [:]
        for e in expanded { byID[e.id] = e }
        return layoutParagraphs(order: order, byID: byID, styles: styles, textPosX: textPosX, textPosY: textPosY, textWidth: textWidth, anchors: &anchors)
    }

    /// Expands multi-character runs into one item per character so anchors resolve exactly.
    static func expand(_ raw: [SeqItem]) -> [SeqItem] {
        var expanded: [SeqItem] = []
        for item in raw {
            if item.deletedLength > 0 {
                var cur = item.id, left = item.left
                for i in 0..<item.deletedLength {
                    let next = i < item.deletedLength - 1 ? CrdtID(cur.part1, cur.part2 + 1) : item.right
                    expanded.append(SeqItem(id: cur, left: left, right: next, deletedLength: 1, value: .text("")))
                    left = cur
                    cur = next
                }
            } else if case .format = item.value {
                expanded.append(item)
            } else if case .text(let s) = item.value, !s.isEmpty {
                let chars = Array(s)
                var cur = item.id, left = item.left
                for (i, ch) in chars.enumerated() {
                    let next = i < chars.count - 1 ? CrdtID(cur.part1, cur.part2 + 1) : item.right
                    expanded.append(SeqItem(id: cur, left: left, right: next, deletedLength: 0, value: .text(String(ch))))
                    left = cur
                    cur = next
                }
            }
        }

        return expanded
    }

    static func layoutParagraphs(order: [CrdtID], byID: [CrdtID: SeqItem], styles: [CrdtID: ParagraphStyle], textPosX: Float, textPosY: Float,
                                 textWidth: Float, anchors: inout [CrdtID: Float]) -> ([TypedParagraph], [CrdtID: Float]) {
        var paragraphs: [TypedParagraph] = []
        // Per paragraph: its start ID and each character's ID with its UTF-16 offset in the text.
        var anchorIDs: [(start: CrdtID, chars: [(CrdtID, Int)])] = []
        var idx = 0
        while idx < order.count {
            var startID = CrdtID.end
            if let first = byID[order[idx]], first.deletedLength == 0, case .text("\n") = first.value {
                startID = first.id
                idx += 1
            }
            var text = ""
            var charIDs: [(CrdtID, Int)] = []
            var utf16 = 0
            var inlineBold = false
            while idx < order.count, let cur = byID[order[idx]] {
                if cur.deletedLength > 0 { idx += 1; continue }
                if case .format(let f) = cur.value {
                    if f == 1 { inlineBold = true } else if f == 2 { inlineBold = false }
                    idx += 1
                } else if case .text(let s) = cur.value {
                    if s == "\n" { break }
                    text += s
                    charIDs.append((cur.id, utf16))
                    utf16 += s.utf16.count
                    idx += 1
                } else {
                    idx += 1
                }
            }
            let base = styles[startID] ?? .plain
            let style: ParagraphStyle = (base == .plain && inlineBold && !text.isEmpty) ? .bold : base
            paragraphs.append(TypedParagraph(text: text, style: style))
            anchorIDs.append((startID, charIDs))
        }

        // Anchors come from the wrapped layout the renderer draws, so ink stays next to its text.
        let (laid, bottom) = TypedTextLayout.layout(paragraphs, posX: textPosX, posY: textPosY, width: textWidth)
        for (p, ids) in zip(laid, anchorIDs) {
            anchors[ids.start] = Float(p.anchorY(forOffset: 0))
            for (id, offset) in ids.chars { anchors[id] = Float(p.anchorY(forOffset: offset)) }
        }
        anchors[anchorTop] = textPosY + textTopY
        anchors[anchorBottom] = Float(bottom)
        return (paragraphs, anchors)
    }

    // MARK: CRDT ordering

    static func toposortValues(_ items: [SeqItem]) -> [Value] {
        if items.count <= 1 { return items.filter { $0.deletedLength == 0 }.map(\.value) }
        var byID: [CrdtID: SeqItem] = [:]
        for i in items { byID[i.id] = i }
        // Preserve first-seen order for duplicate ids, then sort.
        var seen = Set<CrdtID>()
        let unique = items.filter { seen.insert($0.id).inserted }.map { byID[$0.id]! }
        return toposortIDs(unique).compactMap { id in byID[id].flatMap { $0.deletedLength == 0 ? $0.value : nil } }
    }

    /// Orders sequence items by their left/right neighbour links (Kahn's algorithm with a deterministic tie-break).
    static func toposortIDs(_ items: [SeqItem]) -> [CrdtID] {
        guard !items.isEmpty else { return [] }
        var known = Set<CrdtID>()
        for i in items { known.insert(i.id) }

        var inDegree: [CrdtID: Int] = [.startSentinel: 0, .endSentinel: 0]
        var dependents: [CrdtID: [CrdtID]] = [:]
        for item in items {
            let left = (item.left == .end || !known.contains(item.left)) ? CrdtID.startSentinel : item.left
            let right = (item.right == .end || !known.contains(item.right)) ? CrdtID.endSentinel : item.right
            inDegree[item.id, default: 0] += 1
            dependents[left, default: []].append(item.id)
            inDegree[right, default: 0] += 1
            dependents[item.id, default: []].append(right)
        }

        var heap = Heap<CrdtID>(by: CrdtID.readyOrder)
        for (n, d) in inDegree where d == 0 { heap.push(n) }
        var result: [CrdtID] = []
        result.reserveCapacity(items.count)
        var emitted = Set<CrdtID>()
        while let node = heap.pop() {
            if known.contains(node), emitted.insert(node).inserted { result.append(node) }
            if node == .endSentinel { break }
            for dep in dependents[node] ?? [] {
                let d = (inDegree[dep] ?? 1) - 1
                inDegree[dep] = d
                if d == 0 { heap.push(dep) }
            }
        }
        if result.count < known.count {
            for i in items where !emitted.contains(i.id) {
                emitted.insert(i.id)
                result.append(i.id)
            }
        }
        return result
    }
}

// MARK: - Primitives

struct CrdtID: Hashable {
    var part1: Int
    var part2: UInt64
    init(_ p1: Int, _ p2: UInt64) { part1 = p1; part2 = p2 }

    static let end = CrdtID(0, 0)
    static let startSentinel = CrdtID(-1, 0)
    static let endSentinel = CrdtID(Int.max, 0)

    private var rank: Int { self == .startSentinel ? 0 : self == .endSentinel ? 2 : 1 }

    /// Same tie-break as the Kotlin/rmscene implementation: sentinel rank, then part1 descending, then part2.
    static func readyOrder(_ a: CrdtID, _ b: CrdtID) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        if a.part1 != b.part1 { return a.part1 > b.part1 }
        return a.part2 < b.part2
    }
}

struct Heap<T> {
    private var items: [T] = []
    private let less: (T, T) -> Bool
    init(by less: @escaping (T, T) -> Bool) { self.less = less }

    mutating func push(_ x: T) {
        items.append(x)
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            guard less(items[i], items[p]) else { break }
            items.swapAt(i, p)
            i = p
        }
    }

    mutating func pop() -> T? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < items.count, less(items[l], items[m]) { m = l }
            if r < items.count, less(items[r], items[m]) { m = r }
            if m == i { break }
            items.swapAt(i, m)
            i = m
        }
        return top
    }
}

enum Tag {
    static let id = 0xF, length4 = 0xC, byte8 = 0x8, byte4 = 0x4, byte1 = 0x1
}

struct ReaderError: Error {}

/// Little-endian cursor over the tagged rmscene encoding.
struct ByteReader {
    let data: [UInt8]
    var pos: Int
    var limit: Int

    init(_ data: [UInt8], pos: Int) {
        self.data = data
        self.pos = pos
        self.limit = data.count
    }

    mutating func u8() throws -> UInt8 {
        guard pos < data.count else { throw ReaderError() }
        defer { pos += 1 }
        return data[pos]
    }

    mutating func u16() throws -> UInt16 { UInt16(try u8()) | UInt16(try u8()) << 8 }

    mutating func u32() throws -> UInt32 {
        guard pos + 4 <= data.count else { throw ReaderError() }
        let v = UInt32(data[pos]) | UInt32(data[pos + 1]) << 8 | UInt32(data[pos + 2]) << 16 | UInt32(data[pos + 3]) << 24
        pos += 4
        return v
    }

    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    mutating func f64() throws -> Double {
        let lo = UInt64(try u32()), hi = UInt64(try u32())
        return Double(bitPattern: lo | hi << 32)
    }

    mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n > 0 else { return [] }
        guard pos + n <= data.count else { throw ReaderError() }
        defer { pos += n }
        return data[pos..<pos + n]
    }

    mutating func varuint() throws -> UInt64 {
        var shift: UInt64 = 0, result: UInt64 = 0
        while shift < 64 {
            let b = try u8()
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        return result
    }

    mutating func rawID() throws -> CrdtID { CrdtID(Int(try u8()), try varuint()) }

    mutating func tagHeader() throws -> (Int, Int) {
        let x = try varuint()
        return (Int(x >> 4), Int(x & 0xF))
    }

    private mutating func expect(_ index: Int, _ type: Int) throws {
        let saved = pos
        let (i, t) = try tagHeader()
        guard i == index, t == type else { pos = saved; throw ReaderError() }
    }

    func peek(_ index: Int, _ type: Int, limit: Int? = nil) -> Bool {
        let lim = limit ?? self.limit
        guard pos < lim else { return false }
        var copy = self
        guard let (i, t) = try? copy.tagHeader() else { return false }
        return i == index && t == type && copy.pos <= lim
    }

    func hasSubblock(_ index: Int, limit: Int? = nil) -> Bool { peek(index, Tag.length4, limit: limit) }

    /// Reads a uint32 length and returns the end offset of the payload that follows it.
    mutating func enterLength4() throws -> Int {
        let len = Int(try u32())
        return min(pos + len, data.count)
    }

    mutating func subblock(_ index: Int) throws -> Int {
        try expect(index, Tag.length4)
        return try enterLength4()
    }

    mutating func id(_ index: Int) throws -> CrdtID { try expect(index, Tag.id); return try rawID() }
    mutating func bool(_ index: Int) throws -> Bool { try expect(index, Tag.byte1); return try u8() != 0 }
    mutating func int(_ index: Int) throws -> UInt32 { try expect(index, Tag.byte4); return try u32() }
    mutating func float(_ index: Int) throws -> Float { try expect(index, Tag.byte4); return try f32() }
    mutating func double(_ index: Int) throws -> Double { try expect(index, Tag.byte8); return try f64() }

    mutating func optionalInt(_ index: Int, limit: Int) -> UInt32? {
        peek(index, Tag.byte4, limit: limit) ? try? int(index) : nil
    }

    mutating func optionalFloat(_ index: Int, limit: Int) -> Float? {
        peek(index, Tag.byte4, limit: limit) ? try? float(index) : nil
    }

    mutating func string(_ index: Int) throws -> String {
        let end = try subblock(index)
        let len = Int(try varuint())
        _ = try u8()
        let s = String(decoding: try bytes(min(len, end - pos)), as: UTF8.self)
        pos = end
        return s
    }

    mutating func lwwBool() throws -> Bool {
        let end = try enterLength4(); _ = try id(1); let v = try bool(2); pos = end; return v
    }

    mutating func lwwID() throws -> CrdtID {
        let end = try enterLength4(); _ = try id(1); let v = try id(2); pos = end; return v
    }

    mutating func lwwFloat() throws -> Float {
        let end = try enterLength4(); _ = try id(1); let v = try float(2); pos = end; return v
    }

    mutating func lwwString() throws -> String {
        let end = try enterLength4(); _ = try id(1); let v = try string(2); pos = end; return v
    }

    mutating func skip(_ type: Int, limit: Int) throws {
        switch type {
        case Tag.id: _ = try rawID()
        case Tag.byte1: pos = min(pos + 1, limit)
        case Tag.byte4: pos = min(pos + 4, limit)
        case Tag.byte8: pos = min(pos + 8, limit)
        case Tag.length4: pos = min(try enterLength4(), limit)
        default: pos = limit
        }
    }
}
