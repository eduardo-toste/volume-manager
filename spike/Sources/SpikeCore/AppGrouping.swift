/// Pure grouping logic (SPEC 4.1). No Core Audio / AppKit here so it is unit-testable.
public enum AppOwner: Equatable, Sendable {
    /// Owner is the outermost `.app` bundle at this path.
    case app(path: String)
    /// Last-resort owner: a bundle ID prefix.
    case bundlePrefix(String)
    /// No owner could be determined (system service, daemon...).
    case none
}

/// How an owner was resolved.
public enum GroupingMethod: String, Equatable, Sendable {
    case executablePath = "path"
    case responsibleProcess = "responsible"
    case bundlePrefix = "prefix"
    case none = "none"
}

public enum AppGrouping {
    /// Returns the outermost `X.app` path if `executablePath` lies inside `…/X.app/Contents/…`.
    public static func outermostAppPath(in executablePath: String) -> String? {
        guard executablePath.hasPrefix("/") else { return nil }
        let parts = executablePath.split(separator: "/", omittingEmptySubsequences: true)
        for index in parts.indices where parts[index].hasSuffix(".app") && parts[index].count > 4 {
            let next = parts.index(after: index)
            if next < parts.endIndex, parts[next] == "Contents" {
                return "/" + parts[parts.startIndex...index].joined(separator: "/")
            }
        }
        return nil
    }

    /// Heuristic bundle ID prefix: first three reverse-DNS components (`com.vendor.App.helper` -> `com.vendor.App`).
    public static func fallbackBundlePrefix(_ bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }

    /// Resolves the owner in SPEC order: path, responsible process path, bundle ID prefix.
    public static func resolve(
        executablePath: String?,
        responsiblePath: String?,
        bundleID: String?
    ) -> (owner: AppOwner, method: GroupingMethod) {
        if let path = executablePath, let app = outermostAppPath(in: path) {
            return (.app(path: app), .executablePath)
        }
        if let path = responsiblePath, let app = outermostAppPath(in: path) {
            return (.app(path: app), .responsibleProcess)
        }
        if let id = bundleID, let prefix = fallbackBundlePrefix(id) {
            return (.bundlePrefix(prefix), .bundlePrefix)
        }
        return (.none, .none)
    }
}

/// Untrusted-text handling (SPEC 12.9.4).
public enum Sanitize {
    /// Truncates to `limit` characters and replaces control characters with `?`.
    public static func text(_ input: String, limit: Int = 200) -> String {
        let cleaned = input.unicodeScalars.map { scalar -> Character in
            scalar.value < 0x20 || scalar.value == 0x7F ? "?" : Character(scalar)
        }
        return String(cleaned.prefix(limit))
    }
}
