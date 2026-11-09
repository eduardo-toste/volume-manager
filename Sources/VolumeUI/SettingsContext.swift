import AppKit
import VolumeCore

/// Everything the settings window needs, injected by the composition root.
@MainActor
public struct SettingsContext {
  let settings: SettingsModel
  let store: MixerStore
  let loginItem: LoginItemModel
  let icon: @MainActor (String) -> NSImage?
  /// Display name of an installed app by bundle ID, or `nil`.
  let appName: @MainActor (String) -> String?
  let version: String
  let build: String
  let openRepository: @MainActor () -> Void

  /// Creates the context. `version` and `build` come from the app bundle.
  public init(
    settings: SettingsModel, store: MixerStore, loginItem: LoginItemModel,
    icon: @escaping @MainActor (String) -> NSImage?,
    appName: @escaping @MainActor (String) -> String?,
    version: String, build: String, openRepository: @escaping @MainActor () -> Void
  ) {
    self.settings = settings
    self.store = store
    self.loginItem = loginItem
    self.icon = icon
    self.appName = appName
    self.version = version
    self.build = build
    self.openRepository = openRepository
  }
}

/// One line of the "Aplicativos" list: a remembered app, ready to show.
struct RememberedRow: Identifiable, Equatable {
  let bundleID: String
  let name: String
  let percent: Int
  let muted: Bool
  /// Name of the saved output, or `nil` for the system default.
  let outputName: String?
  /// True when the saved output is not connected now.
  let outputMissing: Bool

  var id: String { bundleID }

  /// Remembered apps by name, then bundle ID. A name that cannot be found falls back to the
  /// bundle ID, shown as plain text.
  @MainActor
  static func rows(
    settings: SettingsModel, devices: [OutputDevice], name: (String) -> String?
  ) -> [RememberedRow] {
    settings.rememberedApps.map { bundleID, record in
      let device = record.outputUID.flatMap { uid in devices.first { $0.uid == uid } }
      return RememberedRow(
        bundleID: bundleID, name: name(bundleID) ?? bundleID,
        percent: RowPresentation.percent(record.volume), muted: record.muted,
        outputName: device?.displayName, outputMissing: record.outputUID != nil && device == nil)
    }
    .sorted {
      ($0.name.localizedLowercase, $0.bundleID) < ($1.name.localizedLowercase, $1.bundleID)
    }
  }
}
