import Foundation

/// reMarkable models, as in the web and Android apps (screen in pixels, landscape-first like theirs).
public enum DeviceProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case paperPro = "rmpro"
    case paperProMove = "rmpro_move"
    case rm2 = "rm2"
    case rm1 = "rm1"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .paperPro: return "reMarkable Paper Pro"
        case .paperProMove: return "reMarkable Paper Pro (Move / Landscape)"
        case .rm2: return "reMarkable 2"
        case .rm1: return "reMarkable 1"
        }
    }

    public var width: Int { self == .paperProMove ? 1620 : self == .paperPro ? 2160 : 1872 }
    public var height: Int { self == .paperProMove ? 2160 : self == .paperPro ? 1620 : 1404 }
    public var ppi: Int { self == .rm2 || self == .rm1 ? 226 : 229 }
    public var isColor: Bool { self == .paperPro || self == .paperProMove }

    /// Portrait page size in pixels (the way documents are read).
    public var portrait: (width: Int, height: Int) { (min(width, height), max(width, height)) }

    /// The profile chosen in Settings (default Paper Pro).
    public static var current: DeviceProfile {
        DeviceProfile(rawValue: UserDefaults.standard.string(forKey: "deviceProfile") ?? "") ?? .paperPro
    }
}

/// The converter's 5-stop quality slider (same stops as the web and Android apps).
public struct QualityProfile: Sendable, Equatable {
    public let stop: Int
    public let name: String
    public let maxWidth: Int
    public let maxHeight: Int
    public let jpegQuality: Double
    public let description: String

    public static let stops: [QualityProfile] = [
        .init(stop: 1, name: "Smallest", maxWidth: 1200, maxHeight: 1600, jpegQuality: 0.65, description: "Fastest page turns, ultra-low memory (~75% reduction)"),
        .init(stop: 2, name: "Compact", maxWidth: 1440, maxHeight: 1920, jpegQuality: 0.72, description: "Snappy paging with great legibility (~65% reduction)"),
        .init(stop: 3, name: "Balanced", maxWidth: 1620, maxHeight: 2160, jpegQuality: 0.82, description: "1:1 native reMarkable pixel match (device screen target). Recommended"),
        .init(stop: 4, name: "Sharp", maxWidth: 1920, maxHeight: 2560, jpegQuality: 0.88, description: "Crisp fine text and detailed line art (~40% reduction)"),
        .init(stop: 5, name: "Best", maxWidth: 2250, maxHeight: 3000, jpegQuality: 0.92, description: "Maximum preservation of master scans (~10% reduction)"),
    ]

    public static func stop(_ n: Int) -> QualityProfile { stops[min(max(n, 1), 5) - 1] }
}
