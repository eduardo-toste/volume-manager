import AppKit
import CSystemShims
import Foundation
import Synchronization
import VolumeCore

/// The app that currently has keyboard focus. Text is sanitized.
public struct FrontmostApplication: Sendable, Hashable {
  /// Process identifier.
  public let pid: Int32
  /// Bundle identifier, if the app has one.
  public let bundleID: String?
  /// Display name, if available.
  public let name: String?
}

/// `AppInfoProvider` over `NSWorkspace`, `Bundle`, `proc_pidpath` and the one allowed private
/// call (`responsibility_get_pid_responsible_for_pid`, weak-linked).
///
/// Everything it returns about other processes is untrusted: text goes through `TextSanitizer`,
/// paths through `AppPath`.
public final class WorkspaceAppInfoProvider: AppInfoProvider, Sendable {
  /// Most icons kept in memory.
  public static let iconCacheLimit = 200

  private let icons = Mutex(
    LRUCache<String, NSImage>(capacity: WorkspaceAppInfoProvider.iconCacheLimit))

  /// Creates a provider with an empty icon cache.
  public init() {}

  // MARK: Processes

  /// Executable path of a running process, canonicalized, or `nil` if it is gone, unreadable,
  /// too long or contains control characters.
  public func executablePath(forPID pid: Int32) -> String? {
    guard pid > 0 else { return nil }
    // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; the macro is not imported into Swift.
    let capacity = 4 * Int(MAXPATHLEN)
    var buffer = [UInt8](repeating: 0, count: capacity)
    let length = proc_pidpath(pid, &buffer, UInt32(capacity))
    guard length > 0, Int(length) <= capacity else { return nil }
    guard let text = String(validating: buffer[0..<Int(length)], as: UTF8.self) else { return nil }
    return AppPath.canonicalize(text)
  }

  /// True if `pid` is still running the executable at `expectedPath` (guards against PID reuse,
  /// SPEC 12.9.4).
  public func pidStillMatches(_ pid: Int32, executablePath expectedPath: String) -> Bool {
    guard let expected = AppPath.canonicalize(expectedPath),
      let current = executablePath(forPID: pid)
    else { return false }
    return current == expected
  }

  /// The "responsible" process of `pid` (for example the browser that owns a helper), or `nil`
  /// when the system call fails or names the process itself.
  ///
  /// The function is weak-imported, but Swift cannot reliably test whether the symbol exists:
  /// if a future macOS removed it, this call would crash. The user accepted that risk
  /// (SPEC 4.1, review finding M-1); the release script checks the symbol on every supported
  /// macOS version (PLAN M7).
  public func responsiblePID(forPID pid: Int32) -> Int32? {
    guard pid > 0 else { return nil }
    let responsible = responsibility_get_pid_responsible_for_pid(pid)
    guard responsible > 0, responsible != pid else { return nil }
    return responsible
  }

  /// Path of the `.app` that owns the responsible process of `pid`, or `nil`.
  public func responsibleAppPath(forPID pid: Int32) -> String? {
    guard let responsible = responsiblePID(forPID: pid),
      let path = executablePath(forPID: responsible)
    else { return nil }
    return AppPath.outermostAppPath(in: path)
  }

  // MARK: Apps

  /// Display name of the `.app` at `appPath`, sanitized, or `nil`.
  public func appName(atAppPath appPath: String) -> String? {
    guard let path = Self.validAppPath(appPath) else { return nil }
    var candidates: [String] = []
    if let info = Bundle(path: path)?.infoDictionary {
      for key in ["CFBundleDisplayName", "CFBundleName"] {
        if let value = info[key] as? String { candidates.append(value) }
      }
    }
    let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    candidates.append(fileName)
    for candidate in candidates {
      let clean = TextSanitizer.clean(candidate)
      if !clean.isEmpty { return clean }
    }
    return nil
  }

  /// Bundle identifier of the `.app` at `appPath`, sanitized, or `nil`.
  public func bundleID(atAppPath appPath: String) -> String? {
    guard let path = Self.validAppPath(appPath),
      let identifier = Bundle(path: path)?.bundleIdentifier
    else { return nil }
    let clean = TextSanitizer.clean(identifier)
    return clean.isEmpty ? nil : clean
  }

  /// The app in the foreground, or `nil`.
  public func frontmostApplication() -> FrontmostApplication? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let identifier = app.bundleIdentifier.map { TextSanitizer.clean($0) }
    let name = app.localizedName.map { TextSanitizer.clean($0) }
    return FrontmostApplication(
      pid: app.processIdentifier,
      bundleID: identifier?.isEmpty == false ? identifier : nil,
      name: name?.isEmpty == false ? name : nil)
  }

  // MARK: Icons

  /// Icon of the app with `bundleID`, cached by bundle ID (at most `iconCacheLimit` entries,
  /// least recently used evicted), or `nil` if the app cannot be found.
  public func icon(forBundleID bundleID: String) -> NSImage? {
    let key = TextSanitizer.clean(bundleID)
    guard !key.isEmpty else { return nil }
    if let cached = icons.withLock({ $0.value(for: key) }) { return cached }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) else {
      return nil
    }
    let image = NSWorkspace.shared.icon(forFile: url.path)
    icons.withLock { $0.insert(image, for: key) }
    return image
  }

  private static func validAppPath(_ path: String) -> String? {
    guard let canonical = AppPath.canonicalize(path), canonical.lowercased().hasSuffix(".app")
    else { return nil }
    return canonical
  }
}
