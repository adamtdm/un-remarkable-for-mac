import Foundation

public enum AppVersion {
    /// Versions are decimals ("0.26" < "0.3" == "0.30"); anything with more dots compares component by component.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines).trimmingPrefix("v")
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines).trimmingPrefix("v")
        let posix = Locale(identifier: "en_US_POSIX")
        if a.filter({ $0 == "." }).count <= 1, b.filter({ $0 == "." }).count <= 1,
           let da = Decimal(string: String(a), locale: posix), let db = Decimal(string: String(b), locale: posix) {
            return da > db
        }
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
