import Foundation

/// Writes reMarkable v6 `.rm` page files containing typed text.
///
/// A port of rmscene's `simple_text_document` (what the web app uses to create notebooks), extended with
/// paragraph styles (headings, bold, bullets, checkboxes). Output is byte-identical to rmscene for the same
/// author ID; see the writer fixtures in the tests.
public enum RmWriter {
    public struct Paragraph: Sendable, Equatable {
        public var text: String
        public var style: ParagraphStyle
        public init(_ text: String, style: ParagraphStyle = .plain) {
            self.text = text
            self.style = style
        }
    }

    /// One page of plain typed text. Lines are separated by "\n".
    public static func page(text: String, author: UUID = UUID()) -> Data {
        // Like rmscene, plain text carries a single style entry; unstyled paragraphs default to plain.
        page(paragraphs: text.components(separatedBy: "\n").map { Paragraph($0) }, author: author, styleEveryParagraph: false)
    }

    /// One page of styled paragraphs.
    public static func page(paragraphs: [Paragraph], author: UUID = UUID()) -> Data {
        page(paragraphs: paragraphs, author: author, styleEveryParagraph: true)
    }

    static func page(paragraphs: [Paragraph], author: UUID, styleEveryParagraph: Bool) -> Data {
        let paragraphs = paragraphs.isEmpty ? [Paragraph("")] : paragraphs
        let text = paragraphs.map(\.text).joined(separator: "\n")
        // CRDT character IDs count Unicode scalars (rmscene uses Python string indices).
        let scalarCount = text.unicodeScalars.count

        var w = TaggedWriter()
        w.bytes(Array("reMarkable .lines file, version=6          ".utf8))

        // Author IDs
        w.block(type: 0x09, min: 1, current: 1) { w in
            w.varuint(1)
            w.subblock(0) { w in
                let le = uuidBytesLE(author)
                w.varuint(UInt64(le.count))
                w.bytes(le)
                w.u16(1)
            }
        }
        // Migration info
        w.block(type: 0x00, min: 1, current: 1) { w in
            w.id(1, (1, 1))
            w.bool(2, true)
            w.bool(3, false)
        }
        // Page info
        w.block(type: 0x0A, min: 0, current: 1) { w in
            w.int(1, 1)
            w.int(2, 0)
            w.int(3, UInt32(scalarCount + 1))
            w.int(4, UInt32(text.filter { $0 == "\n" }.count + 1))
            w.int(5, 0)
        }
        // Scene tree: layer node (0,11) under the root group (0,1)
        w.block(type: 0x01, min: 1, current: 1) { w in
            w.id(1, (0, 11))
            w.id(2, (0, 0))
            w.bool(3, true)
            w.subblock(4) { w in w.id(1, (0, 1)) }
        }
        // Root text
        rootTextBlock(&w, paragraphs: paragraphs, text: text, styleEveryParagraph: styleEveryParagraph)
        // Tree nodes: root group and "Layer 1"
        w.block(type: 0x02, min: 1, current: 2) { w in
            w.id(1, (0, 1))
            w.lwwString(2, timestamp: (0, 0), "")
            w.lwwBool(3, timestamp: (0, 0), true)
        }
        w.block(type: 0x02, min: 1, current: 2) { w in
            w.id(1, (0, 11))
            w.lwwString(2, timestamp: (0, 12), "Layer 1")
            w.lwwBool(3, timestamp: (0, 0), true)
        }
        // Scene group item: puts the layer in the root group
        w.block(type: 0x04, min: 1, current: 1) { w in
            w.id(1, (0, 1))
            w.id(2, (0, 13))
            w.id(3, (0, 0))
            w.id(4, (0, 0))
            w.int(5, 0)
            w.subblock(6) { w in
                w.u8(0x02)
                w.id(2, (0, 11))
            }
        }
        return Data(w.out)
    }

    static func rootTextBlock(_ w: inout TaggedWriter, paragraphs: [Paragraph], text: String, styleEveryParagraph: Bool) {
        w.block(type: 0x07, min: 1, current: 1) { w in
            w.id(1, (0, 0))
            w.subblock(2) { w in
                w.subblock(1) { w in
                    w.subblock(1) { w in
                        w.varuint(1)
                        w.subblock(0) { w in
                            w.id(2, (1, 16))
                            w.id(3, (0, 0))
                            w.id(4, (0, 0))
                            w.int(5, 0)
                            if !text.isEmpty { w.string(6, text) }
                        }
                    }
                }
                // Paragraph styles, keyed by the ID of the newline that starts each paragraph.
                var styles: [((UInt8, UInt64), ParagraphStyle)] = [((0, 0), paragraphs[0].style)]
                var offset = 0
                for (i, p) in paragraphs.enumerated() {
                    if i > 0, styleEveryParagraph { styles.append(((1, UInt64(16 + offset - 1)), p.style)) }
                    offset += p.text.unicodeScalars.count + 1
                }
                w.subblock(2) { w in
                    w.subblock(1) { w in
                        w.varuint(UInt64(styles.count))
                        for (charID, style) in styles {
                            w.crdtID(charID)
                            w.id(1, (1, 15))
                            w.subblock(2) { w in
                                w.u8(17)
                                w.u8(UInt8(style.rawValue))
                            }
                        }
                    }
                }
            }
            w.subblock(3) { w in
                w.f64(-468)
                w.f64(234)
            }
            w.float(4, 936)
        }
    }

    /// Replaces the typed text of an existing page, keeping its handwriting and everything else.
    /// Like the web app's `update_rm_text_in_bytes`. Pages that aren't v6 are rebuilt from scratch.
    public static func replacingText(in existing: Data, paragraphs: [Paragraph]) -> Data {
        let header = Array("reMarkable .lines file, version=6          ".utf8)
        let bytes = [UInt8](existing)
        guard bytes.count > header.count, Array(bytes[0..<header.count]) == header else {
            return page(paragraphs: paragraphs)
        }
        let paragraphs = paragraphs.isEmpty ? [Paragraph("")] : paragraphs
        let text = paragraphs.map(\.text).joined(separator: "\n")
        var newRoot = TaggedWriter()
        rootTextBlock(&newRoot, paragraphs: paragraphs, text: text, styleEveryParagraph: true)

        var out = header
        var pos = header.count
        var replaced = false
        while pos + 8 <= bytes.count {
            let len = Int(UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24)
            let type = bytes[pos + 7]
            let end = pos + 8 + len
            guard end <= bytes.count else { break }
            if type == 0x07 {
                out += newRoot.out
                replaced = true
            } else {
                out += bytes[pos..<end]
            }
            pos = end
        }
        if !replaced { out += newRoot.out }
        return Data(out)
    }

    /// UUID bytes in the little-endian field layout (Python's `uuid.bytes_le`).
    static func uuidBytesLE(_ u: UUID) -> [UInt8] {
        let b = withUnsafeBytes(of: u.uuid) { Array($0) }
        return Array(b[0..<4].reversed()) + Array(b[4..<6].reversed()) + Array(b[6..<8].reversed()) + Array(b[8..<16])
    }
}

/// rmscene's TaggedBlockWriter: tagged values, length-prefixed blocks and subblocks.
struct TaggedWriter {
    var out: [UInt8] = []

    mutating func bytes(_ b: [UInt8]) { out += b }
    mutating func u8(_ v: UInt8) { out.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out += $0 } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out += $0 } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { out += $0 } }

    mutating func varuint(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
    }

    mutating func tag(_ index: Int, _ type: UInt8) { varuint(UInt64(index << 4) | UInt64(type)) }
    mutating func crdtID(_ id: (UInt8, UInt64)) {
        u8(id.0)
        varuint(id.1)
    }

    mutating func id(_ index: Int, _ v: (UInt8, UInt64)) { tag(index, 0xF); crdtID(v) }
    mutating func bool(_ index: Int, _ v: Bool) { tag(index, 0x1); u8(v ? 1 : 0) }
    mutating func int(_ index: Int, _ v: UInt32) { tag(index, 0x4); u32(v) }
    mutating func float(_ index: Int, _ v: Float) { tag(index, 0x4); f32(v) }

    mutating func string(_ index: Int, _ s: String) {
        subblock(index) { w in
            let b = Array(s.utf8)
            w.varuint(UInt64(b.count))
            w.u8(1) // "is ascii" flag; rmscene always writes 1
            w.bytes(b)
        }
    }

    mutating func lwwString(_ index: Int, timestamp: (UInt8, UInt64), _ s: String) {
        subblock(index) { w in
            w.id(1, timestamp)
            w.string(2, s)
        }
    }

    mutating func lwwBool(_ index: Int, timestamp: (UInt8, UInt64), _ v: Bool) {
        subblock(index) { w in
            w.id(1, timestamp)
            w.bool(2, v)
        }
    }

    mutating func subblock(_ index: Int, _ body: (inout TaggedWriter) -> Void) {
        var inner = TaggedWriter()
        body(&inner)
        tag(index, 0xC)
        u32(UInt32(inner.out.count))
        out += inner.out
    }

    mutating func block(type: UInt8, min: UInt8, current: UInt8, _ body: (inout TaggedWriter) -> Void) {
        var inner = TaggedWriter()
        body(&inner)
        u32(UInt32(inner.out.count))
        u8(0)
        u8(min)
        u8(current)
        u8(type)
        out += inner.out
    }
}

// MARK: - Appending typed text without touching existing text

extension RmWriter {
    /// Appends paragraphs after the last character of a page's typed text, the way the tablet does: every
    /// existing text item keeps its bytes and ID (so handwriting anchored to the text stays put) and one
    /// new item is added. Returns nil if the page has no typed text block (callers fall back to
    /// `replacingText`).
    public static func appendingText(to existing: Data, paragraphs new: [Paragraph]) -> Data? {
        guard !new.isEmpty else { return existing }
        let bytes = [UInt8](existing)
        let header = Array("reMarkable .lines file, version=6          ".utf8)
        guard bytes.count > header.count, Array(bytes[0..<header.count]) == header else { return nil }

        // Find the RootText block.
        var pos = header.count
        var found: (start: Int, payload: Range<Int>)?
        while pos + 8 <= bytes.count {
            let len = Int(u32(bytes, pos))
            let end = pos + 8 + len
            guard end <= bytes.count else { return nil }
            if bytes[pos + 7] == 0x07 { found = (pos, (pos + 8)..<end) }
            pos = end
        }
        guard let block = found else { return nil }
        var r = Cursor(bytes: bytes, pos: block.payload.lowerBound)

        do {
            // id(1)
            let idStart = r.pos
            try r.expectTag(1, 0xF); _ = try r.crdtID()
            let idBytes = Array(bytes[idStart..<r.pos])
            // subblock 2 { subblock 1 { subblock 1 { count, items… } }, [subblock 2 { subblock 1 { count, styles… } }] }
            let sub2End = try r.subblock(2)
            let sub21End = try r.subblock(1)
            let sub211End = try r.subblock(1)
            let itemCount = try r.varuint()
            let itemsStart = r.pos
            var items: [RmParser.SeqItem] = []
            for _ in 0..<itemCount {
                let itemEnd = try r.subblock(0)
                try r.expectTag(2, 0xF); let id = try r.crdtID()
                try r.expectTag(3, 0xF); let left = try r.crdtID()
                try r.expectTag(4, 0xF); let right = try r.crdtID()
                try r.expectTag(5, 0x4); let del = Int(r.u32())
                var value = RmParser.Value.text("")
                if r.pos < itemEnd, let t = r.peekTag(), t == (6, 0xC) {
                    let strEnd = try r.subblock(6)
                    let n = Int(try r.varuint())
                    r.pos += 1
                    let s = String(decoding: bytes[r.pos..<min(r.pos + n, strEnd)], as: UTF8.self)
                    value = s.isEmpty ? .format(0) : .text(s)
                }
                r.pos = itemEnd
                items.append(.init(id: id, left: left, right: right, deletedLength: del, value: value))
            }
            let itemsBlob = Array(bytes[itemsStart..<sub211End])
            r.pos = sub211End
            r.pos = sub21End
            var styleCount: UInt64 = 0
            var stylesBlob: [UInt8] = []
            if r.pos < sub2End, let t = r.peekTag(), t == (2, 0xC) {
                let sub22End = try r.subblock(2)
                let sub221End = try r.subblock(1)
                styleCount = try r.varuint()
                stylesBlob = Array(bytes[r.pos..<sub221End])
                r.pos = sub22End
            }
            let remainder = Array(bytes[sub2End..<block.payload.upperBound])

            // Where to attach: the last character in document order; new IDs above every counter used.
            let order = RmParser.toposortIDs(RmParser.expand(items))
            let last = order.last ?? CrdtID(0, 0)
            let maxCounter = items.reduce(UInt64(0)) { m, i in
                let len: UInt64 = { if case .text(let s) = i.value { return UInt64(max(s.unicodeScalars.count, 1)) } else { return UInt64(max(i.deletedLength, 1)) } }()
                return max(m, i.id.part2 + len)
            }
            let author: UInt8 = 1
            let base = maxCounter + 10
            let text = "\n" + new.map(\.text).joined(separator: "\n")
            var newStyles: [((UInt8, UInt64), ParagraphStyle, UInt64)] = []
            var offset: UInt64 = 0
            let stampBase = base + UInt64(text.unicodeScalars.count) + 10
            for (i, p) in new.enumerated() {
                newStyles.append(((author, base + offset), p.style, stampBase + UInt64(i)))
                offset += UInt64(p.text.unicodeScalars.count) + 1
            }

            var w = TaggedWriter()
            w.bytes(idBytes)
            w.subblock(2) { w in
                w.subblock(1) { w in
                    w.subblock(1) { w in
                        w.varuint(itemCount + 1)
                        w.bytes(itemsBlob)
                        w.subblock(0) { w in
                            w.id(2, (author, base))
                            w.id(3, (UInt8(clamping: last.part1), last.part2))
                            w.id(4, (0, 0))
                            w.int(5, 0)
                            w.string(6, text)
                        }
                    }
                }
                w.subblock(2) { w in
                    w.subblock(1) { w in
                        w.varuint(styleCount + UInt64(newStyles.count))
                        w.bytes(stylesBlob)
                        for (charID, style, stamp) in newStyles {
                            w.crdtID(charID)
                            w.id(1, (author, stamp))
                            w.subblock(2) { w in w.u8(17); w.u8(UInt8(style.rawValue)) }
                        }
                    }
                }
            }
            w.bytes(remainder)

            var out = Array(bytes[0..<block.start])
            var len = UInt32(w.out.count).littleEndian
            withUnsafeBytes(of: &len) { out += $0 }
            out += bytes[(block.start + 4)..<(block.start + 8)] // unknown, min/current version, type
            out += w.out
            out += bytes[block.payload.upperBound...]
            return Data(out)
        } catch {
            return nil
        }
    }

    static func u32(_ b: [UInt8], _ p: Int) -> UInt32 {
        UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
    }

    /// Reads rmscene's tagged values.
    struct Cursor {
        let bytes: [UInt8]
        var pos: Int
        struct Malformed: Error {}

        mutating func varuint() throws -> UInt64 {
            var v: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard pos < bytes.count else { throw Malformed() }
                let b = bytes[pos]; pos += 1
                v |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return v }
                shift += 7
                if shift > 63 { throw Malformed() }
            }
        }
        mutating func u32() -> UInt32 { defer { pos += 4 }; return RmWriter.u32(bytes, pos) }
        func peekTag() -> (Int, UInt8)? {
            var c = self
            guard let t = try? c.varuint() else { return nil }
            return (Int(t >> 4), UInt8(t & 0xF))
        }
        mutating func expectTag(_ index: Int, _ type: UInt8) throws {
            let t = try varuint()
            guard Int(t >> 4) == index, UInt8(t & 0xF) == type else { throw Malformed() }
        }
        mutating func crdtID() throws -> CrdtID {
            guard pos < bytes.count else { throw Malformed() }
            let p1 = Int(bytes[pos]); pos += 1
            return CrdtID(p1, try varuint())
        }
        /// Enters a length-prefixed subblock; returns its end position.
        mutating func subblock(_ index: Int) throws -> Int {
            try expectTag(index, 0xC)
            guard pos + 4 <= bytes.count else { throw Malformed() }
            let len = Int(u32())
            guard pos + len <= bytes.count else { throw Malformed() }
            return pos + len
        }
    }
}
