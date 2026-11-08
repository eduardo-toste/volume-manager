import AppKit
import Darwin
import Foundation
import Synchronization
import Testing
import VolumeCore

@testable import VolumeSystem

// MARK: Helpers

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func bump() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}

private final class QAController: AppServiceControlling, @unchecked Sendable {
  struct Failure: Error {}
  private let lock = NSLock()
  private var current: AppServiceState
  private(set) var registers = 0
  private(set) var unregisters = 0
  var failing = false
  init(_ state: AppServiceState) { current = state }
  func state() -> AppServiceState { lock.withLock { current } }
  func register() throws {
    try lock.withLock {
      registers += 1
      if failing { throw NSError(domain: "x", code: 42) }
      current = .enabled
    }
  }
  func unregister() throws {
    try lock.withLock {
      unregisters += 1
      if failing { throw NSError(domain: "x", code: 43) }
      current = .notRegistered
    }
  }
  func openSettings() {}
}

private final class QAProbe: AudioAccessProbe, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  var callCount: Int { lock.withLock { calls } }
  func probe() -> Bool {
    lock.withLock {
      calls += 1
      return calls.isMultiple(of: 2)
    }
  }
}

/// Builds a throwaway `.app` with the given Info.plist in the temporary directory and removes
/// it afterwards. The app has no executable and is never launched.
private func withFakeApp(
  fileName: String = "Fake.app", info: [String: Any], _ body: (String) throws -> Void
) throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("vm-qa-m3-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let contents = root.appendingPathComponent("\(fileName)/Contents")
  try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
  let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
  try data.write(to: contents.appendingPathComponent("Info.plist"))
  try body(root.appendingPathComponent(fileName).path)
}

private func forbiddenScalars(in text: String) -> Bool {
  text.unicodeScalars.contains {
    switch $0.properties.generalCategory {
    case .control, .format: return true
    default: return false
    }
  }
}

// MARK: Process / PID

@Suite("QA M3: PIDs and paths")
struct QAPIDTests {
  private let provider = WorkspaceAppInfoProvider()

  @Test(arguments: [Int32.min, -1, 0, Int32.max, 99_999_999])
  func hostilePIDsGiveNil(pid: Int32) {
    #expect(provider.executablePath(forPID: pid) == nil)
    #expect(provider.responsiblePID(forPID: pid) == nil)
    #expect(provider.responsibleAppPath(forPID: pid) == nil)
    #expect(!provider.pidStillMatches(pid, executablePath: "/bin/sleep"))
  }

  @Test func resultNeverHasControlsAndIsBounded() {
    for app in NSWorkspace.shared.runningApplications {
      if let path = provider.executablePath(forPID: app.processIdentifier) {
        #expect(path.hasPrefix("/"))
        #expect(path.utf8.count <= AppPath.maxLength)
        #expect(!path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
      }
    }
  }

  @Test func revalidationMatchesNonCanonicalSpellingOfSameExecutable() throws {
    let pid = ProcessInfo.processInfo.processIdentifier
    let path = try #require(provider.executablePath(forPID: pid))
    #expect(provider.pidStillMatches(pid, executablePath: "/." + path))
    #expect(provider.pidStillMatches(pid, executablePath: "/tmp/.." + path))
    #expect(!provider.pidStillMatches(pid, executablePath: path + "\u{0}"))
    #expect(!provider.pidStillMatches(pid, executablePath: ""))
  }

  /// A process that dies: the PID must stop resolving and stop matching (TOCTOU window).
  @Test func exitedProcessNoLongerResolvesOrMatches() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    let pid = child.processIdentifier
    defer {
      if child.isRunning {
        child.terminate()
        child.waitUntilExit()
      }
    }
    let path = try #require(provider.executablePath(forPID: pid))
    #expect(provider.pidStillMatches(pid, executablePath: path))
    child.terminate()
    child.waitUntilExit()
    #expect(provider.executablePath(forPID: pid) == nil)
    #expect(!provider.pidStillMatches(pid, executablePath: path))
  }

  /// Another executable running under the SAME PID value is what reuse looks like; the match
  /// must be by path, so a different program with this PID is rejected.
  @Test func differentExecutableForSamePIDIsRejected() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer {
      child.terminate()
      child.waitUntilExit()
    }
    #expect(!provider.pidStillMatches(child.processIdentifier, executablePath: "/usr/bin/true"))
  }
}

// MARK: Hostile bundles

@Suite("QA M3: hostile app bundles")
struct QAHostileBundleTests {
  private let provider = WorkspaceAppInfoProvider()
  private let hostile = "A\u{202E}B\u{200B}C\u{0007}D\u{2066}E\nF\u{FEFF}"

  @Test func hostileDisplayNameIsSanitized() throws {
    try withFakeApp(info: ["CFBundleDisplayName": hostile, "CFBundleIdentifier": "com.x.y"]) {
      let name = provider.appName(atAppPath: $0)
      #expect(name == "ABCDE F")
      #expect(!forbiddenScalars(in: name ?? ""))
    }
  }

  @Test func tenKilobyteNameIsBounded() throws {
    let huge = String(repeating: "N", count: 10_240)
    try withFakeApp(info: ["CFBundleDisplayName": huge]) {
      let name = provider.appName(atAppPath: $0)
      #expect((name?.count ?? 0) <= TextSanitizer.maxLength)
      #expect(name?.isEmpty == false)
    }
  }

  @Test func giantBundleIDIsBoundedAndSanitized() throws {
    let huge = "com." + String(repeating: "a\u{202E}", count: 10_000)
    try withFakeApp(info: ["CFBundleIdentifier": huge]) {
      let id = provider.bundleID(atAppPath: $0)
      #expect((id?.count ?? 0) <= TextSanitizer.maxLength)
      #expect(!forbiddenScalars(in: id ?? ""))
    }
  }

  @Test func nameOfOnlyInvisibleCharactersFallsBack() throws {
    try withFakeApp(
      fileName: "Real Name.app",
      info: ["CFBundleDisplayName": "\u{202E}\u{200B}\u{0007}", "CFBundleName": "\u{202E}"]
    ) {
      #expect(provider.appName(atAppPath: $0) == "Real Name")
    }
  }

  @Test func nonStringInfoValuesAreIgnored() throws {
    try withFakeApp(
      fileName: "Plain.app",
      info: ["CFBundleDisplayName": ["a", "b"], "CFBundleName": 7, "CFBundleIdentifier": ["x"]]
    ) {
      #expect(provider.appName(atAppPath: $0) == "Plain")
      #expect(provider.bundleID(atAppPath: $0) == nil)
    }
  }

  @Test func hostilePathsAreRejected() {
    #expect(provider.appName(atAppPath: "/x/\u{0007}/Evil.app") == nil)
    #expect(provider.appName(atAppPath: "/" + String(repeating: "a", count: 2000) + ".app") == nil)
    #expect(provider.appName(atAppPath: "") == nil)
    #expect(provider.bundleID(atAppPath: "/x/../../etc/passwd") == nil)
    #expect(provider.appName(atAppPath: "/nonexistent/\u{202E}Evil\u{200B}.app") == nil)
  }

  @Test func iconLookupWithHostileBundleIDsIsSafe() {
    #expect(provider.icon(forBundleID: String(repeating: "x", count: 100_000)) == nil)
    #expect(provider.icon(forBundleID: "\u{202E}\u{0000}\u{200B}") == nil)
    #expect(provider.icon(forBundleID: "   ") == nil)
  }

  @Test func concurrentIconLookupsAreSafe() async {
    let ids = [
      "com.apple.finder", "com.apple.Safari", "com.apple.systempreferences", "no.such.app",
    ]
    let provider = provider
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<400 {
        group.addTask { _ = provider.icon(forBundleID: ids[index % ids.count]) }
      }
    }
  }
}

// MARK: LRU

@Suite("QA M3: LRU under concurrency")
struct QALRUTests {
  @Test func limitHoldsUnderConcurrentInsertsThroughMutex() async {
    let cache = Mutex(LRUCache<Int, Int>(capacity: WorkspaceAppInfoProvider.iconCacheLimit))
    await withTaskGroup(of: Void.self) { group in
      for worker in 0..<8 {
        group.addTask {
          for index in 0..<2_000 {
            let key = worker * 10_000 + index
            cache.withLock { $0.insert(key, for: key) }
            _ = cache.withLock { $0.value(for: key / 2) }
          }
        }
      }
    }
    #expect(cache.withLock { $0.count } <= WorkspaceAppInfoProvider.iconCacheLimit)
    #expect(cache.withLock { $0.count } == WorkspaceAppInfoProvider.iconCacheLimit)
  }

  @Test func orderAndValuesStayConsistent() {
    var cache = LRUCache<Int, Int>(capacity: 3)
    for index in 0..<50 {
      cache.insert(index, for: index % 7)
      _ = cache.value(for: (index * 3) % 7)
      #expect(cache.count <= 3)
    }
  }

  @Test func capacityIsClampedForNegative() {
    var cache = LRUCache<Int, Int>(capacity: -5)
    cache.insert(1, for: 1)
    cache.insert(2, for: 2)
    #expect(cache.count == 1)
  }
}

// MARK: Preferences

@MainActor
@Suite("QA M3: preferences hostile input")
struct QAPreferencesTests {
  private func withStore(
    _ body: (UserDefaultsPreferencesStore, InMemoryPreferencesBackend) throws -> Void
  ) throws {
    let backend = InMemoryPreferencesBackend()
    try body(UserDefaultsPreferencesStore(backend: backend), backend)
  }

  @Test func nestedNonFiniteAndForeignTypesAreRejected() throws {
    try withStore { store, defaults in
      store.set([["a": Double.nan]] as [Any], forKey: "nestedNaN")
      store.set(Float.infinity, forKey: "floatInf")
      store.set(NSDecimalNumber.notANumber, forKey: "decimalNaN")
      store.set(NSNull(), forKey: "null")
      store.set(URL(string: "https://example.com")!, forKey: "url")
      store.set(["k": [1: 2]] as [String: Any], forKey: "nestedIntKeys")
      store.set(NSAttributedString(string: "x"), forKey: "attr")
      for key in ["nestedNaN", "floatInf", "decimalNaN", "null", "url", "nestedIntKeys", "attr"] {
        #expect(defaults.object(forKey: key) == nil, "\(key) must not be stored")
      }
    }
  }

  @Test func depthBoundaryAcceptsFourAndRejectsFive() throws {
    try withStore { store, defaults in
      var ok: Any = 1
      for _ in 0..<UserDefaultsPreferencesStore.maxDepth { ok = [ok] }
      store.set(ok, forKey: "ok")
      #expect(defaults.object(forKey: "ok") != nil)
      store.set([ok], forKey: "tooDeep")
      #expect(defaults.object(forKey: "tooDeep") == nil)
    }
  }

  @Test func hostileKeysDoNotCrash() throws {
    try withStore { store, defaults in
      for key in ["\u{0000}", "a\u{0000}b", "\u{202E}k", " ", "../../x", "k.with.dots"] {
        store.set(1, forKey: key)
        _ = store.object(forKey: key)
        store.set(nil, forKey: key)
      }
      #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("k.with") }.isEmpty)
    }
  }

  /// `key.count` counts grapheme clusters, so 200 "characters" can be hundreds of kilobytes.
  @Test func keyLimitIsBoundedInBytesNotOnlyCharacters() throws {
    try withStore { store, defaults in
      let key = "e" + String(repeating: "\u{0301}", count: 50_000)  // 1 character, 100 KB
      store.set(1, forKey: key)
      #expect(defaults.object(forKey: key) == nil, "a 100 KB key must be refused")
    }
  }

  @Test func neverWritesToStandardDefaults() throws {
    let marker = "vm.qa.m3.\(UUID().uuidString)"
    try withStore { store, _ in store.set(1, forKey: marker) }
    #expect(UserDefaults.standard.object(forKey: marker) == nil)
  }
}

// MARK: Login item

@Suite("QA M3: login item")
struct QALoginItemTests {
  @Test func enableFromRequiresApprovalDoesNotReRegister() throws {
    let fake = QAController(.requiresApproval)
    try SMAppLoginItemService(controller: fake).setEnabled(true)
    #expect(fake.registers == 0)
  }

  @Test func disableFromNotRegisteredAndNotFoundNeverUnregisters() throws {
    for state in [AppServiceState.notRegistered, .notFound] {
      let fake = QAController(state)
      try SMAppLoginItemService(controller: fake).setEnabled(false)
      #expect(fake.unregisters == 0)
    }
  }

  @Test func disableFromRequiresApprovalUnregisters() throws {
    let fake = QAController(.requiresApproval)
    try SMAppLoginItemService(controller: fake).setEnabled(false)
    #expect(fake.unregisters == 1)
  }

  @Test func errorsCarryCodeAndLeaveStatusUnchanged() {
    let fake = QAController(.notRegistered)
    fake.failing = true
    let service = SMAppLoginItemService(controller: fake)
    #expect(throws: LoginItemError.registrationFailed(code: 42)) { try service.setEnabled(true) }
    #expect(service.status() == .disabled)
    let enabled = QAController(.enabled)
    enabled.failing = true
    #expect(throws: LoginItemError.unregistrationFailed(code: 43)) {
      try SMAppLoginItemService(controller: enabled).setEnabled(false)
    }
  }

  @Test func readingStatusAndOpeningSettingsNeverMutate() {
    let fake = QAController(.notRegistered)
    let service = SMAppLoginItemService(controller: fake)
    for _ in 0..<20 { _ = service.status() }
    service.openLoginItemsSettings()
    #expect(fake.registers == 0 && fake.unregisters == 0)
  }

  @Test func toggleSequenceIsIdempotent() throws {
    let fake = QAController(.notRegistered)
    let service = SMAppLoginItemService(controller: fake)
    for _ in 0..<3 { try service.setEnabled(true) }
    for _ in 0..<3 { try service.setEnabled(false) }
    #expect(fake.registers == 1 && fake.unregisters == 1)
  }
}

// MARK: Permission service

@Suite("QA M3: permission service")
struct QAPermissionTests {
  @Test func concurrentRequestsAreSerializedAndEndConsistent() async {
    let probe = QAProbe()
    let service = AudioPermissionService(probe: probe)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<20 { group.addTask { _ = await service.request() } }
    }
    #expect(probe.callCount == 20)
    let status = await service.request()
    #expect(status == .granted || status == .denied)
  }

  @Test func settingsURLIsTheFixedConstant() {
    let url = AudioPermissionService.privacySettingsURL
    #expect(url?.scheme == "x-apple.systempreferences")
    #expect(url?.absoluteString.hasSuffix("Privacy_AudioCapture") == true)
  }
}

// MARK: Session lifecycle

@MainActor
@Suite("QA M3: session lifecycle")
struct QALifecycleTests {
  @Test func stopIsIdempotentAndNothingFiresAfterIt() {
    let workspace = NotificationCenter()
    let app = NotificationCenter()
    let counter = Counter()
    let observer = SessionLifecycleObserver(workspaceCenter: workspace, appCenter: app) {
      counter.bump()
    }
    observer.stop()
    observer.stop()
    workspace.post(name: NSWorkspace.willPowerOffNotification, object: nil)
    app.post(name: NSApplication.willTerminateNotification, object: nil)
    #expect(counter.count == 0)
  }

  @Test func eventsOnTheWrongCenterAreIgnored() {
    let workspace = NotificationCenter()
    let app = NotificationCenter()
    let counter = Counter()
    let observer = SessionLifecycleObserver(workspaceCenter: workspace, appCenter: app) {
      counter.bump()
    }
    workspace.post(name: NSApplication.willTerminateNotification, object: nil)
    app.post(name: NSWorkspace.willPowerOffNotification, object: nil)
    #expect(counter.count == 0)
    observer.stop()
  }

  @Test func repeatedEventsDeliverEachTime() {
    let workspace = NotificationCenter()
    let app = NotificationCenter()
    let counter = Counter()
    let observer = SessionLifecycleObserver(workspaceCenter: workspace, appCenter: app) {
      counter.bump()
    }
    for _ in 0..<3 { workspace.post(name: NSWorkspace.willPowerOffNotification, object: nil) }
    #expect(counter.count == 3)
    observer.stop()
  }

  /// No retain cycle: dropping the observer without `stop()` frees it and silences it.
  @Test func observerIsReleasedAndSilentWithoutStop() {
    let workspace = NotificationCenter()
    let app = NotificationCenter()
    let counter = Counter()
    weak var weakObserver: SessionLifecycleObserver?
    do {
      let observer = SessionLifecycleObserver(workspaceCenter: workspace, appCenter: app) {
        counter.bump()
      }
      weakObserver = observer
    }
    #expect(weakObserver == nil)
    workspace.post(name: NSWorkspace.willPowerOffNotification, object: nil)
    #expect(counter.count == 0)
  }
}
