import AppKit
import SwiftUI
import Testing
import VolumeCore

@testable import VolumeUI

// Snapshots of the settings window and the welcome window (PLAN M5), from fakes only: no
// real preferences, no login item registered, no Core Audio. VM_WRITE_SNAPSHOTS=1 rewrites
// Tests/Snapshots/*.png, git-ignored (helpers in SnapshotTests.swift).

private final class QuietLoginItem: LoginItemService, Sendable {
  let state: LoginItemStatus
  init(_ state: LoginItemStatus = .enabled) { self.state = state }
  func status() -> LoginItemStatus { state }
  func setEnabled(_ enabled: Bool) throws {}
  func openLoginItemsSettings() {}
}

/// The test process has no app bundle, so the real icon is loaded from `Resources/`.
@MainActor
private func useAppIcon() {
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/AppIcon-1024.png")
  if let icon = NSImage(contentsOf: url) { NSApplication.shared.applicationIconImage = icon }
}

@MainActor
private func settingsContext(
  _ fixture: Fixture, loginItem: LoginItemStatus = .enabled
) -> SettingsContext {
  SettingsContext(
    settings: fixture.settings, store: fixture.store,
    loginItem: LoginItemModel(service: QuietLoginItem(loginItem)),
    icon: { _ in nil },
    appName: { id in FixedAppInfo.apps.first { $0.bundleID == id }?.name },
    version: "1.0.0", build: "1", openRepository: {})
}

@MainActor
@Suite("Settings and welcome snapshots (fakes only)", .serialized, .timeLimit(.minutes(1)))
struct SettingsSnapshotTests {
  @Test func everySettingsPane() async {
    useAppIcon()
    let scene = await Fixture(apps: ["Spotify"])
    scene.settings.remember(
      AppAudioState(volume: 0.72, preferredOutputUID: "airpods"), for: "com.spotify.client")
    scene.settings.remember(AppAudioState(volume: 0.4, muted: true), for: "com.apple.Safari")
    scene.settings.remember(AppAudioState(volume: 1, preferredOutputUID: "gone"), for: "com.x.Y")
    let context = settingsContext(scene)
    for (name, pane) in [
      ("settings-general", SettingsPane.general), ("settings-apps", .apps),
      ("settings-devices", .devices), ("settings-about", .about),
    ] {
      snapshot(name, SettingsView(context: context, pane: pane), width: 780)
    }
  }

  @Test func emptyAppsAndApprovalHint() async {
    let scene = await Fixture(apps: [])
    snapshot(
      "settings-apps-empty", SettingsView(context: settingsContext(scene), pane: .apps), width: 780)
    snapshot(
      "settings-general-approval",
      SettingsView(context: settingsContext(scene, loginItem: .requiresApproval), pane: .general),
      width: 780)
  }

  @Test func welcome() async {
    useAppIcon()
    let scene = await Fixture(apps: [])
    let model = WelcomeModel(
      settings: scene.settings,
      loginItem: LoginItemModel(service: QuietLoginItem(.disabled)),
      store: scene.store, permission: scene.permission)
    snapshot("welcome", WelcomeView(model: model, onStart: {}), width: 480)
  }

  @Test func rememberedRowsAreSortedAndNameTheirOutput() async {
    let scene = await Fixture(apps: [])
    scene.settings.remember(
      AppAudioState(volume: 0.72, preferredOutputUID: "airpods"), for: "com.spotify.client")
    scene.settings.remember(AppAudioState(volume: 0.4, muted: true), for: "com.apple.Safari")
    scene.settings.remember(AppAudioState(volume: 1, preferredOutputUID: "gone"), for: "com.x.Y")
    let rows = RememberedRow.rows(
      settings: scene.settings, devices: scene.store.devices,
      name: { id in FixedAppInfo.apps.first { $0.bundleID == id }?.name })
    #expect(rows.map(\.name) == ["com.x.Y", "Safari", "Spotify"])
    #expect(rows.first { $0.name == "Spotify" }?.outputName == "AirPods Pro")
    #expect(rows.first { $0.name == "Spotify" }?.percent == 72)
    #expect(rows.first { $0.name == "Safari" }?.muted == true)
    #expect(rows.first { $0.name == "Safari" }?.outputName == nil)
    #expect(rows.first { $0.name == "com.x.Y" }?.outputMissing == true)
    scene.settings.forget("com.x.Y")
    #expect(
      RememberedRow.rows(settings: scene.settings, devices: [], name: { _ in nil }).count == 2)
    scene.settings.forgetAll()
    #expect(RememberedRow.rows(settings: scene.settings, devices: [], name: { _ in nil }).isEmpty)
  }
}
