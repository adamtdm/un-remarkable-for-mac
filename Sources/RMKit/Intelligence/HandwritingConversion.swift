import Foundation

/// reMarkable's own handwriting conversion (`/convert/v1/handwriting`, MyScript behind it), as the tablet and
/// desktop app use for "Convert to text". Works with any reMarkable Connect account and needs no AI provider.
/// Request: MyScript batch JSON (`strokeGroups`, `xDPI`/`yDPI`, `contentType`, `configuration`); response: JIIX.
public enum HandwritingConversion {
    /// The tablet's resolution; v6 page coordinates are tablet pixels.
    static let dpi = 226

    /// Tablet language codes MyScript accepts.
    public static let languages: [(code: String, name: String)] = [
        ("en_US", "English (US)"), ("en_GB", "English (UK)"), ("de_DE", "German"), ("fr_FR", "French"),
        ("es_ES", "Spanish"), ("it_IT", "Italian"), ("nl_NL", "Dutch"), ("sv_SE", "Swedish"),
        ("nb_NO", "Norwegian"), ("da_DK", "Danish"), ("fi_FI", "Finnish"), ("pt_PT", "Portuguese"),
        ("pl_PL", "Polish"), ("ja_JP", "Japanese"), ("zh_CN", "Chinese (Simplified)"),
    ]

    /// The supported language closest to the Mac's locale.
    public static var defaultLanguage: String {
        let id = Locale.current.identifier(.icu)
        if let exact = languages.first(where: { id.hasPrefix($0.code) }) { return exact.code }
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        return languages.first { $0.code.hasPrefix(lang + "_") }?.code ?? "en_US"
    }

    /// Strokes worth recognising: writing tools only (no eraser, highlighter or shader), at least two points.
    static func strokes(_ page: RmPage) -> [Stroke] {
        page.layers.flatMap(\.strokes).filter { s in
            s.points.count > 1 && ![.eraser, .highlighter, .shader].contains(s.tool)
        }
    }

    public static func hasHandwriting(_ page: RmPage) -> Bool { !strokes(page).isEmpty }

    /// The MyScript batch request body for a page's ink.
    public static func requestBody(_ page: RmPage, language: String = "en_US") throws -> Data {
        let dx: Float = page.centerOriginX ? Float(page.width) / 2 : 0
        let strokes: [[String: Any]] = strokes(page).map { s in
            [
                "x": s.points.map { Double(($0.x + dx) * 10).rounded() / 10 },
                "y": s.points.map { Double($0.y * 10).rounded() / 10 },
            ]
        }
        let body: [String: Any] = [
            "xDPI": dpi, "yDPI": dpi,
            "contentType": "Text",
            "width": page.width, "height": page.height,
            "configuration": [
                "lang": language,
                "export": ["jiix": ["strokes": false, "text": ["chars": false, "words": true]]],
            ] as [String: Any],
            "strokeGroups": [["strokes": strokes]],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// The recognised text from a JIIX response (a Text block's `label`, or the labels of Raw Content's text elements).
    public static func text(fromJIIX data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let label = obj["label"] as? String { return label.trimmingCharacters(in: .whitespacesAndNewlines) }
        let elements = obj["elements"] as? [[String: Any]] ?? []
        return elements.compactMap { $0["label"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension CloudClient {
    /// Converts a page's handwriting to text with reMarkable's cloud service. Empty for pages without ink.
    public func convertHandwriting(_ page: RmPage, language: String = "en_US") async throws -> String {
        guard HandwritingConversion.hasHandwriting(page) else { return "" }
        let body = try HandwritingConversion.requestBody(page, language: language)
        let data = try await send(path: "/convert/v1/handwriting", method: "POST", body: body, headers: [
            "Content-Type": "application/json",
            "Accept": "application/vnd.myscript.jiix",
        ])
        return HandwritingConversion.text(fromJIIX: data)
    }
}
