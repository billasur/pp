import Foundation

/// Version comparison for the numeric prefixes pp uses in manifests.
public enum PpVersion {
    /// -1 when lhs is older, 0 when equal, 1 when newer. Missing components are zero,
    /// so "1.2" and "1.2.0" compare equal.
    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let left = parts(lhs), right = parts(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }
}
