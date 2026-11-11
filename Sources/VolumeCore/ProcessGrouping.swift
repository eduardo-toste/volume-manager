/// Groups audio processes under the app that owns them (SPEC 4.1).
public enum ProcessGrouping {
  /// Where a process was assigned.
  private enum Owner {
    case app(path: String)
    case bundlePrefix(String)
  }

  /// One group while it is being built.
  private struct Draft {
    var name: String
    var bundleID: String?
    var pids: Set<Int32> = []
    var isPlaying = false
    var isInCall = false
  }

  /// Longest bundle ID accepted.
  private static let maxBundleIDLength = 200

  /// Groups `processes` into apps, sorted by `id`. Order of resolution for each process:
  /// 1. the outermost `.app` containing its executable (path canonicalized);
  /// 2. the `.app` of the process the system holds responsible for it;
  /// 3. the first three components of its bundle ID.
  ///
  /// Excluded: the app itself (by bundle ID, by `Volume Manager.app` path or by `excludedPID`, also as
  /// responsible process) and system daemons without an app.
  public static func group(
    _ processes: [AudioProcessInfo],
    info: some AppInfoProvider,
    excludedBundleID: String = AppIdentity.bundleIdentifier,
    excludedPID: Int32? = nil
  ) -> [AudioApp] {
    var drafts: [String: Draft] = [:]
    for process in processes where process.pid > 0 {
      if let excludedPID, process.pid == excludedPID || process.responsiblePID == excludedPID {
        continue
      }
      guard let owner = resolveOwner(of: process, info: info) else { continue }
      let (key, bundleID, fallbackName) = identity(of: owner, info: info)
      if isExcluded(process: process, groupBundleID: bundleID, excluded: excludedBundleID)
        || (bundleID == nil && fallbackName == AppIdentity.displayName
          && isAppOwner(owner))
      {
        continue
      }
      let name = displayName(owner: owner, info: info, fallback: fallbackName)
      var draft = drafts[key] ?? Draft(name: name, bundleID: bundleID)
      draft.pids.insert(process.pid)
      draft.isPlaying = draft.isPlaying || process.isRunningOutput
      draft.isInCall = draft.isInCall || process.isRunningInput
      drafts[key] = draft
    }
    return drafts.keys.sorted().compactMap { key in
      guard let draft = drafts[key] else { return nil }
      return AudioApp(
        id: key, name: draft.name, bundleID: draft.bundleID, pids: draft.pids.sorted(),
        isPlaying: draft.isPlaying, isInCall: draft.isInCall)
    }
  }

  /// Returns a bundle ID only if it is plain reverse-DNS text of a sane length.
  public static func validBundleID(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty, raw.utf8.count <= maxBundleIDLength else { return nil }
    let allowed = raw.utf8.allSatisfy { byte in
      (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
        || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2E || byte == 0x2D || byte == 0x5F
    }
    return allowed ? raw : nil
  }

  /// First three reverse-DNS components (`com.vendor.App.helper` becomes `com.vendor.App`).
  public static func bundlePrefix(_ bundleID: String) -> String {
    bundleID.split(separator: ".", omittingEmptySubsequences: true).prefix(3)
      .joined(separator: ".")
  }

  private static func resolveOwner(of process: AudioProcessInfo, info: some AppInfoProvider)
    -> Owner?
  {
    let ownPath = process.executablePath ?? info.executablePath(forPID: process.pid)
    if let ownPath, let app = AppPath.outermostAppPath(in: ownPath) { return .app(path: app) }
    if let responsible = process.responsiblePID, responsible > 0, responsible != process.pid,
      let path = info.executablePath(forPID: responsible),
      let app = AppPath.outermostAppPath(in: path)
    {
      return .app(path: app)
    }
    if let ownPath, let canonical = AppPath.canonicalize(ownPath),
      AppPath.isSystemPath(canonical)
    {
      return nil
    }
    guard let bundleID = validBundleID(process.bundleID) else { return nil }
    let prefix = bundlePrefix(bundleID)
    return prefix.isEmpty ? nil : .bundlePrefix(prefix)
  }

  private static func isAppOwner(_ owner: Owner) -> Bool {
    if case .app = owner { return true }
    return false
  }

  private static func identity(of owner: Owner, info: some AppInfoProvider)
    -> (key: String, bundleID: String?, fallbackName: String)
  {
    switch owner {
    case .app(let path):
      let bundleID = validBundleID(info.bundleID(atAppPath: path))
      let file = path.split(separator: "/").last.map(String.init) ?? ""
      let base = file.lowercased().hasSuffix(".app") ? String(file.dropLast(4)) : file
      return (bundleID ?? "path:\(path)", bundleID, base)
    case .bundlePrefix(let prefix):
      return (prefix, prefix, prefix.split(separator: ".").last.map(String.init) ?? prefix)
    }
  }

  private static func displayName(owner: Owner, info: some AppInfoProvider, fallback: String)
    -> String
  {
    if case .app(let path) = owner {
      let provided = TextSanitizer.clean(info.appName(atAppPath: path) ?? "")
      if !provided.isEmpty { return provided }
    }
    let cleaned = TextSanitizer.clean(fallback)
    return cleaned
  }

  private static func isExcluded(
    process: AudioProcessInfo, groupBundleID: String?, excluded: String
  ) -> Bool {
    if groupBundleID == excluded { return true }
    guard let own = validBundleID(process.bundleID) else { return false }
    return own == excluded || own.hasPrefix(excluded + ".")
  }
}
