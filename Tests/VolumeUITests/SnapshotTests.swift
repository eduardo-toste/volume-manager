import AppKit
import SwiftUI
import Synchronization
import Testing
import VolumeCore

@testable import VolumeUI

// Snapshots of the popover (PLAN M4). Everything is built from fakes: no Core Audio, no taps,
// no sound, the real app is never opened. The views are drawn by AppKit in an off-screen
// window that is never shown. Set VM_WRITE_SNAPSHOTS=1 to rewrite Tests/Snapshots/*.png.

final class QuietAudioSystem: AudioSystem, Sendable {
  func events() -> AsyncStream<AudioSystemEvent> { AsyncStream { _ in } }
  func currentState() async -> AudioSystemSnapshot { AudioSystemSnapshot() }
  func refresh() async {}
  func setMasterVolume(_ volume: Double) async {}
  func setMasterMuted(_ muted: Bool) async {}
  func setDefaultOutput(uid: String) async {}
}

final class QuietController: AppAudioController, Sendable {
  func reconcile(desired: [DesiredAppAudio]) async {}
  func restoreAll() async {}
  func retry(appID: String) async {}
  func retryAll() async {}
}

final class FixedAppInfo: AppInfoProvider, Sendable {
  static let apps: [(name: String, bundleID: String)] = [
    ("Spotify", "com.spotify.client"), ("Safari", "com.apple.Safari"),
    ("Música", "com.apple.Music"), ("Zoom", "us.zoom.xos"), ("Discord", "com.hnc.Discord"),
  ]

  func executablePath(forPID pid: Int32) -> String? { nil }
  func appName(atAppPath appPath: String) -> String? {
    Self.apps.first { appPath.contains("/\($0.name).app") }?.name
  }
  func bundleID(atAppPath appPath: String) -> String? {
    Self.apps.first { appPath.contains("/\($0.name).app") }?.bundleID
  }
}

final class MemoryPreferences: PreferencesStore {
  private var values: [String: Any] = [:]
  func object(forKey key: String) -> Any? { values[key] }
  func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class ScriptedPermission: PermissionService, Sendable {
  let answer: AudioPermissionStatus
  init(_ answer: AudioPermissionStatus) { self.answer = answer }
  func request(userAction: Bool) async -> AudioPermissionStatus { answer }
  func openPrivacySettings() {}
}

@MainActor
struct Fixture {
  let store: MixerStore
  let context: PopoverContext
  let permission: PermissionMonitor
  let settings: SettingsModel

  static let speakers = OutputDevice(id: 1, uid: "speakers", name: "Alto-falantes", kind: .builtIn)
  static let airpods = OutputDevice(id: 2, uid: "airpods", name: "AirPods Pro", kind: .bluetooth)

  init(apps: [String], denied: Bool = false, safeMode: Bool = false) async {
    let preferences = MemoryPreferences()
    let clock = ContinuousClock()
    let settings = SettingsModel(store: preferences, clock: clock)
    let safety = SafetyPolicy(store: preferences, clock: clock)
    if safeMode {
      for _ in 0..<3 { safety.beginSession() }
    }
    let permission = PermissionMonitor(
      service: ScriptedPermission(denied ? .denied : .granted), onGranted: {})
    let store = MixerStore(
      audioSystem: QuietAudioSystem(), controller: QuietController(), appInfo: FixedAppInfo(),
      settings: settings, safety: safety, clock: clock, permission: permission)
    store.handle(.devices([Self.speakers, Self.airpods]))
    store.handle(.defaultOutput(uid: "speakers"))
    store.handle(.master(MasterOutputState(volume: 0.6, isMuted: false)))
    store.handle(
      .processes(
        apps.enumerated().map { index, name in
          AudioProcessInfo(
            pid: Int32(100 + index), executablePath: "/Applications/\(name).app/Contents/MacOS/x",
            isRunningOutput: name != "Zoom")
        }))
    if denied { await permission.refresh(onlyIfDenied: false) }
    self.store = store
    self.permission = permission
    self.settings = settings
    context = PopoverContext(
      store: store, settings: settings, permission: permission,
      icon: { Self.icon(for: $0) },
      openSoundSettings: {}, showSettings: {}, showAbout: {}, quit: {})
  }

  private static func icon(for bundleID: String) -> NSImage? {
    let colors: [String: NSColor] = [
      "com.spotify.client": .systemGreen, "com.apple.Safari": .systemBlue,
      "com.apple.Music": .systemRed, "us.zoom.xos": .systemIndigo, "com.hnc.Discord": .systemPurple,
    ]
    guard let color = colors[bundleID] else { return nil }
    return NSImage(size: NSSize(width: 30, height: 30), flipped: false) { rect in
      color.setFill()
      NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
      return true
    }
  }
}

@MainActor
func render<V: View>(_ view: V, dark: Bool, width: CGFloat) -> NSBitmapImageRep? {
  _ = NSApplication.shared
  let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  let backdrop = dark ? Color(white: 0.16) : Color(white: 0.93)
  let host = NSHostingView(
    rootView: view.frame(width: width).background(backdrop)
      .environment(\.colorScheme, dark ? .dark : .light))
  host.appearance = appearance
  let size = host.fittingSize
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
    backing: .buffered, defer: false)
  window.appearance = appearance
  window.contentView = host
  host.frame = NSRect(origin: .zero, size: size)
  host.layoutSubtreeIfNeeded()
  RunLoop.current.run(until: Date().addingTimeInterval(0.2))
  host.displayIfNeeded()
  guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
  host.cacheDisplay(in: host.bounds, to: rep)
  return rep
}

func isBlank(_ rep: NSBitmapImageRep) -> Bool {
  guard let data = rep.bitmapData else { return true }
  let count = rep.bytesPerRow * rep.pixelsHigh
  let first = data[0]
  return !(0..<count).contains { data[$0] != first }
}

let snapshotsDirectory = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Snapshots")

@MainActor
func snapshot<V: View>(_ name: String, _ view: V, width: CGFloat = 320) {
  for dark in [false, true] {
    guard let rep = render(view, dark: dark, width: width) else {
      Issue.record("could not render \(name)")
      continue
    }
    #expect(!isBlank(rep), "\(name) rendered blank")
    #expect(rep.pixelsWide > 10 && rep.pixelsHigh > 10)
    if ProcessInfo.processInfo.environment["VM_WRITE_SNAPSHOTS"] == "1",
      let png = rep.representation(using: .png, properties: [:])
    {
      try? FileManager.default.createDirectory(
        at: snapshotsDirectory, withIntermediateDirectories: true)
      try? png.write(
        to: snapshotsDirectory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
  }
}

@MainActor
@Suite("Popover snapshots (fakes only)", .serialized, .timeLimit(.minutes(1)))
struct SnapshotTests {
  private let sample = ["Spotify", "Safari", "Música", "Zoom", "Discord"]

  @Test func fullPopover() async {
    let scene = await Fixture(apps: sample)
    scene.store.setVolume(0.72, for: "com.spotify.client")
    scene.store.toggleMute("com.hnc.Discord")
    scene.store.route("com.apple.Safari", to: "airpods")
    scene.store.controlFailed("com.apple.Music")
    snapshot("popover", MenuBarPopover(context: scene.context))
  }

  @Test func rowsNormalMutedFailedExpanded() async {
    let scene = await Fixture(apps: sample)
    scene.store.setVolume(0.72, for: "com.spotify.client")
    scene.store.toggleMute("com.hnc.Discord")
    scene.store.route("com.apple.Safari", to: "airpods")
    scene.store.controlFailed("com.apple.Music")
    scene.store.toggleExpanded("com.apple.Safari")
    let rows = scene.store.rows
    for (name, id) in [
      ("row-normal", "com.spotify.client"), ("row-muted", "com.hnc.Discord"),
      ("row-expanded-routed", "com.apple.Safari"), ("row-failed", "com.apple.Music"),
    ] {
      guard let row = rows.first(where: { $0.id == id }) else {
        Issue.record("missing row \(id)")
        continue
      }
      snapshot(name, AppRowView(row: row, context: scene.context))
    }
  }

  @Test func outputCard() async {
    let scene = await Fixture(apps: sample)
    snapshot("output-card", OutputCard(context: scene.context).padding(12))
  }

  @Test func noPermissionState() async {
    let scene = await Fixture(apps: sample, denied: true)
    #expect(scene.permission.isDenied)
    snapshot("popover-no-permission", MenuBarPopover(context: scene.context))
  }

  @Test func noAppsState() async {
    let scene = await Fixture(apps: [])
    snapshot("popover-no-apps", MenuBarPopover(context: scene.context))
  }

  @Test func safeModeState() async {
    let scene = await Fixture(apps: ["Spotify"], safeMode: true)
    snapshot("popover-safe-mode", MenuBarPopover(context: scene.context))
  }

  /// Bug of the ⏸2 retest: the panel must grow with the apps (no scroll view squeezed to a few
  /// points) and stop at the ceiling, measured the way the window measures it (ideal size).
  @Test func listGrowsWithTheAppsThenStopsAtTheCeiling() async {
    func height(apps count: Int) async -> CGFloat {
      let scene = await Fixture(apps: (0..<count).map { "App\($0)" })
      #expect(scene.store.rows.count == count)
      let host = NSHostingView(rootView: MenuBarPopover(context: scene.context))
      return host.fittingSize.height
    }
    let one = await height(apps: 1)
    let two = await height(apps: 2)
    let three = await height(apps: 3)
    let many = await height(apps: 40)
    let ceiling = MenuBarPopover.maxListHeight(
      screenHeight: NSScreen.main?.visibleFrame.height ?? 900)
    #expect(two - one > 40, "one more app adds a whole row")
    #expect(abs((three - two) - (two - one)) < 1, "every row adds the same height")
    #expect(many > three)
    // Everything but the list, plus the ceiling (a few points for the spacing between rows).
    #expect(many <= one - (two - one) + ceiling + 4, "40 apps stop at the ceiling and scroll")
    #expect(many >= one - (two - one) + ceiling - 4, "the ceiling is used before scrolling")
  }

  /// The panel paints only inside its rounded shape: the corners of the window stay
  /// transparent, so no square background shows behind them (⏸2 retest).
  @Test func cornersOutsideTheRoundedPanelAreTransparent() async {
    let scene = await Fixture(apps: sample)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: MenuBarPopover(context: scene.context))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      Issue.record("could not render")
      return
    }
    host.cacheDisplay(in: host.bounds, to: rep)
    let corners = [
      (0, 0), (rep.pixelsWide - 1, 0), (0, rep.pixelsHigh - 1),
      (rep.pixelsWide - 1, rep.pixelsHigh - 1),
    ]
    for (x, y) in corners {
      #expect((rep.colorAt(x: x, y: y)?.alphaComponent ?? 1) == 0, "corner \(x),\(y)")
    }
    let middle = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
    #expect((middle?.alphaComponent ?? 0) > 0.5, "the panel itself is painted")
  }

  @Test func mountingThePopoverIsFast() async {
    let fixture = await Fixture(apps: sample)
    let clock = ContinuousClock()
    var best = Duration.seconds(10)
    for _ in 0..<5 {
      let elapsed = clock.measure {
        _ = render(MenuBarPopover(context: fixture.context), dark: false, width: 320)
      }
      best = min(best, elapsed)
    }
    // Includes AppKit layout, a 0.2 s run-loop wait and a bitmap draw: a loose upper bound only.
    #expect(best < .seconds(1))
    print("mount+draw best of 5:", best)
  }
}
