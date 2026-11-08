import AppKit
import Foundation
import Testing
import VolumeCore

@testable import VolumeSystem

@Suite("LRUCache")
struct LRUCacheTests {
  @Test func evictsLeastRecentlyUsed() {
    var cache = LRUCache<String, Int>(capacity: 2)
    cache.insert(1, for: "a")
    cache.insert(2, for: "b")
    _ = cache.value(for: "a")  // "b" is now the oldest
    cache.insert(3, for: "c")
    #expect(cache.contains("a"))
    #expect(!cache.contains("b"))
    #expect(cache.contains("c"))
    #expect(cache.count == 2)
  }

  @Test func neverExceedsCapacity() {
    var cache = LRUCache<Int, Int>(capacity: 200)
    for index in 0..<1000 { cache.insert(index, for: index) }
    #expect(cache.count == 200)
    #expect(cache.contains(999))
    #expect(!cache.contains(0))
  }

  @Test func updatingAKeyDoesNotEvict() {
    var cache = LRUCache<String, Int>(capacity: 2)
    cache.insert(1, for: "a")
    cache.insert(2, for: "b")
    cache.insert(9, for: "a")
    #expect(cache.count == 2)
    #expect(cache.value(for: "a") == 9)
    #expect(cache.contains("b"))
  }

  @Test func capacityIsAtLeastOne() {
    var cache = LRUCache<Int, Int>(capacity: 0)
    cache.insert(1, for: 1)
    cache.insert(2, for: 2)
    #expect(cache.count == 1)
  }
}

@Suite("WorkspaceAppInfoProvider")
struct AppInfoProviderTests {
  private let provider = WorkspaceAppInfoProvider()

  @Test func pathOfOwnProcess() throws {
    let path = try #require(
      provider.executablePath(forPID: ProcessInfo.processInfo.processIdentifier))
    #expect(path.hasPrefix("/"))
    #expect(
      provider.pidStillMatches(ProcessInfo.processInfo.processIdentifier, executablePath: path))
  }

  @Test func pathOfInvalidPIDs() {
    #expect(provider.executablePath(forPID: Int32.max) == nil)
    #expect(provider.executablePath(forPID: 0) == nil)
    #expect(provider.executablePath(forPID: -5) == nil)
  }

  @Test func revalidationFailsForDifferentExecutableOrGonePID() {
    let pid = ProcessInfo.processInfo.processIdentifier
    #expect(!provider.pidStillMatches(pid, executablePath: "/usr/bin/true"))
    #expect(!provider.pidStillMatches(pid, executablePath: "relative/path"))
    #expect(!provider.pidStillMatches(Int32.max, executablePath: "/usr/bin/true"))
  }

  @Test func responsiblePIDNeverCrashes() {
    let pid = ProcessInfo.processInfo.processIdentifier
    let responsible = provider.responsiblePID(forPID: pid)
    if let responsible { #expect(responsible > 0 && responsible != pid) }
    #expect(provider.responsiblePID(forPID: Int32.max) == nil)
    #expect(provider.responsiblePID(forPID: -1) == nil)
  }

  /// Skipped (with this reason) unless Safari is running, so a real browser process exists.
  @Test(
    .enabled(
      if: NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == "com.apple.Safari"
      },
      "Safari is not running"))
  func executableOfARealBrowserResolvesToItsApp() throws {
    let running = NSWorkspace.shared.runningApplications.first {
      $0.bundleIdentifier == "com.apple.Safari"
    }
    let pid = try #require(running?.processIdentifier)
    let path = try #require(provider.executablePath(forPID: pid))
    #expect(AppPath.outermostAppPath(in: path)?.hasSuffix("Safari.app") == true)
  }

  @Test func responsibleAppOfRunningProcessesIsAnAppPathOrNil() {
    for app in NSWorkspace.shared.runningApplications.prefix(30) {
      if let path = provider.responsibleAppPath(forPID: app.processIdentifier) {
        #expect(path.hasSuffix(".app"))
      }
    }
  }

  @Test func appNameAndBundleIDOfASystemApp() throws {
    let finder = "/System/Library/CoreServices/Finder.app"
    try #require(FileManager.default.fileExists(atPath: finder), "Finder.app missing")
    #expect(provider.appName(atAppPath: finder) == "Finder")
    #expect(provider.bundleID(atAppPath: finder) == "com.apple.finder")
  }

  @Test func appNameFallsBackToFileNameAndRejectsBadPaths() {
    #expect(provider.appName(atAppPath: "/nonexistent/Fake Thing.app") == "Fake Thing")
    #expect(provider.bundleID(atAppPath: "/nonexistent/Fake Thing.app") == nil)
    #expect(provider.appName(atAppPath: "relative/X.app") == nil)
    #expect(provider.appName(atAppPath: "/usr/bin/true") == nil)
    #expect(provider.appName(atAppPath: "/nonexistent/\u{202E}Evil.app") == nil)
  }

  @Test func iconIsCachedAndUnknownBundleIsNil() throws {
    let first = try #require(provider.icon(forBundleID: "com.apple.finder"))
    let second = try #require(provider.icon(forBundleID: "com.apple.finder"))
    #expect(first === second)
    #expect(provider.icon(forBundleID: "com.example.does.not.exist.\(UUID().uuidString)") == nil)
    #expect(provider.icon(forBundleID: "") == nil)
  }
}
