import AppKit
import Foundation
import VolumeAudio
import VolumeCore
import VolumeSystem
import VolumeUI

/// Composition root: creates the real services, injects them into the domain and connects
/// the controller's failures, the permission and the session lifecycle to it.
@MainActor
final class Composition {
  let settings: SettingsModel
  let store: MixerStore
  let context: PopoverContext

  private let safety: SafetyPolicy
  private let controller: CoreAudioAppController
  private var lifecycle: SessionLifecycleObserver?
  private var tasks: [Task<Void, Never>] = []

  init() {
    let provider = WorkspaceAppInfoProvider()
    let catalog = ProcessCatalog(
      info: provider, responsiblePID: { provider.responsiblePID(forPID: $0) })
    let controller = CoreAudioAppController(
      catalog: catalog, identity: GroupedProcessIdentity(catalog: catalog, info: provider))
    let preferences = UserDefaultsPreferencesStore()
    let clock = ContinuousClock()
    let settings = SettingsModel(store: preferences, clock: clock)
    let safety = SafetyPolicy(store: preferences, clock: clock)
    safety.beginSession()
    let permission = PermissionMonitor(
      service: AudioPermissionService(probe: SystemAudioAccessProbe(catalog: catalog)))
    let store = MixerStore(
      audioSystem: CoreAudioSystem(catalog: catalog), controller: controller,
      appInfo: provider, settings: settings, safety: safety, clock: clock,
      permission: permission, ownPID: ProcessInfo.processInfo.processIdentifier)

    self.controller = controller
    self.settings = settings
    self.safety = safety
    self.store = store
    context = PopoverContext(
      store: store, settings: settings, permission: permission,
      icon: { provider.icon(forBundleID: $0) },
      openSoundSettings: Self.openSoundSettings,
      showAbout: Self.showAbout,
      quit: { Composition.quit(controller: controller, settings: settings, safety: safety) })
  }

  /// Starts listening to the audio system. Called once, at launch.
  func start() {
    guard tasks.isEmpty else { return }
    let failures = controller.failures()
    lifecycle = SessionLifecycleObserver { [settings, safety] in
      settings.flush()
      safety.markCleanExit()
    }
    tasks = [
      Task { [store] in await store.run() },
      Task { [store, controller] in
        // One event at a time, so at most one permission check runs because of silence.
        for await event in failures {
          switch event.reason {
          case .onlySilence, .stillSilent:
            await store.checkSilentTap(mayReuseRecentGrant: event.reason == .stillSilent)
            await controller.silenceChecked(appID: event.appID)
          case .stoppedPlaying:
            store.refreshAudioSystem()
          default:
            // An unsupported output format on an app the user never adjusted is not shown:
            // it plays natively, as without the Volume (logged by the controller).
            store.controlFailed(
              event.appID, quietIfUntouched: event.reason == .incompatibleFormat)
          }
        }
      },
    ]
  }

  // MARK: Actions

  /// Fixed URL (SPEC 12.9.2): System Settings > Sound.
  private static func openSoundSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")
    else { return }
    NSWorkspace.shared.open(url)
  }

  private static func showAbout() {
    NSApp.activate()
    NSApp.orderFrontStandardAboutPanel(nil)
  }

  private static var isQuitting = false
  private static var didTerminate = false

  /// Quits after every tap was destroyed, so every app gets its original audio back (SPEC 8).
  /// Waits at most two seconds for that; taps die with the process anyway.
  private static func quit(
    controller: CoreAudioAppController, settings: SettingsModel, safety: SafetyPolicy
  ) {
    guard !isQuitting else { return }
    isQuitting = true
    func finish() {
      guard !didTerminate else { return }
      didTerminate = true
      settings.flush()
      safety.markCleanExit()
      NSApp.terminate(nil)
    }
    Task {
      await controller.restoreAll()
      finish()
    }
    Task {
      try? await Task.sleep(for: .seconds(2))
      finish()
    }
  }
}
