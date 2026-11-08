import Observation

/// Every user preference of SPEC 3.3, with safe defaults, validated loading and debounced
/// saving.
@MainActor
@Observable
public final class SettingsModel {
  /// Storage keys.
  enum Key {
    static let launchAtLogin = "launchAtLogin"
    static let menuBarIconStyle = "menuBarIconStyle"
    static let rememberVolumes = "rememberVolumes"
    static let showInactiveApps = "showInactiveApps"
    static let volumeStep = "volumeStepPercent"
    static let onboardingCompleted = "onboardingCompleted"
    static let rememberedApps = "rememberedApps"
  }

  /// Time without changes before the preferences are written (SPEC 12.4).
  public static let saveDelay: Duration = .milliseconds(500)

  /// Open the app when the user logs in. Default on.
  public var launchAtLogin = true { didSet { changed(oldValue != launchAtLogin) } }
  /// Style of the menu bar icon. Default speaker.
  public var menuBarIconStyle = MenuBarIconStyle.speaker {
    didSet { changed(oldValue != menuBarIconStyle) }
  }
  /// Remember the volume of each app. Default on.
  public var rememberVolumes = true { didSet { changed(oldValue != rememberVolumes) } }
  /// Keep apps that are not playing in the list. Default off.
  public var showInactiveApps = false { didSet { changed(oldValue != showInactiveApps) } }
  /// Slider increment. Default 5%.
  public var volumeStep = VolumeStep.five { didSet { changed(oldValue != volumeStep) } }
  /// True once the welcome window has been dealt with.
  public var onboardingCompleted = false {
    didSet { changed(oldValue != onboardingCompleted) }
  }
  /// Remembered apps by bundle ID.
  public private(set) var rememberedApps: [String: RememberedApp] = [:]

  @ObservationIgnored private let store: any PreferencesStore
  @ObservationIgnored private let clock: AppClock
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var observers: [@MainActor () -> Void] = []
  @ObservationIgnored private var isLoading = true

  /// Loads and validates the stored preferences. Invalid values become the defaults.
  public init(store: any PreferencesStore, clock: AppClock) {
    self.store = store
    self.clock = clock
    load()
    isLoading = false
  }

  /// Registers a handler called after any preference changes.
  public func onChange(_ handler: @escaping @MainActor () -> Void) {
    observers.append(handler)
  }

  /// What is remembered for `bundleID`.
  public func remembered(for bundleID: String) -> RememberedApp? {
    rememberedApps[bundleID]
  }

  /// Remembers the state of an app. Ignored for bundle IDs that are not valid.
  public func remember(_ state: AppAudioState, for bundleID: String) {
    guard ProcessGrouping.validBundleID(bundleID) != nil else { return }
    let record = RememberedApp(state)
    guard rememberedApps[bundleID] != record else { return }
    guard
      rememberedApps.count < PreferenceValidation.maxRememberedApps
        || rememberedApps[bundleID] != nil
    else { return }
    rememberedApps[bundleID] = record
    changed(true)
  }

  /// Forgets one app.
  public func forget(_ bundleID: String) {
    guard rememberedApps.removeValue(forKey: bundleID) != nil else { return }
    changed(true)
  }

  /// Forgets every app.
  public func forgetAll() {
    guard !rememberedApps.isEmpty else { return }
    rememberedApps = [:]
    changed(true)
  }

  /// Writes everything now and cancels the pending debounced save. Call before quitting.
  public func flush() {
    saveTask?.cancel()
    saveTask = nil
    save()
  }

  private func changed(_ didChange: Bool) {
    guard didChange, !isLoading else { return }
    scheduleSave()
    for observer in observers { observer() }
  }

  private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { [weak self, clock] in
      do { try await clock.sleep(for: SettingsModel.saveDelay) } catch { return }
      self?.flush()
    }
  }

  private func load() {
    launchAtLogin = PreferenceValidation.bool(store.object(forKey: Key.launchAtLogin)) ?? true
    rememberVolumes = PreferenceValidation.bool(store.object(forKey: Key.rememberVolumes)) ?? true
    showInactiveApps =
      PreferenceValidation.bool(store.object(forKey: Key.showInactiveApps)) ?? false
    onboardingCompleted =
      PreferenceValidation.bool(store.object(forKey: Key.onboardingCompleted)) ?? false
    menuBarIconStyle =
      PreferenceValidation.string(store.object(forKey: Key.menuBarIconStyle))
      .flatMap(MenuBarIconStyle.init(rawValue:)) ?? .speaker
    volumeStep =
      PreferenceValidation.integer(store.object(forKey: Key.volumeStep))
      .flatMap(VolumeStep.init(rawValue:)) ?? .five
    rememberedApps = loadRememberedApps()
  }

  private func loadRememberedApps() -> [String: RememberedApp] {
    guard let raw = store.object(forKey: Key.rememberedApps) as? [String: Any] else { return [:] }
    var result: [String: RememberedApp] = [:]
    for (bundleID, value) in raw.sorted(by: { $0.key < $1.key }) {
      guard result.count < PreferenceValidation.maxRememberedApps,
        ProcessGrouping.validBundleID(bundleID) != nil,
        let record = RememberedApp(validating: value)
      else { continue }
      result[bundleID] = record
    }
    return result
  }

  private func save() {
    store.set(launchAtLogin, forKey: Key.launchAtLogin)
    store.set(menuBarIconStyle.rawValue, forKey: Key.menuBarIconStyle)
    store.set(rememberVolumes, forKey: Key.rememberVolumes)
    store.set(showInactiveApps, forKey: Key.showInactiveApps)
    store.set(volumeStep.rawValue, forKey: Key.volumeStep)
    store.set(onboardingCompleted, forKey: Key.onboardingCompleted)
    store.set(rememberedApps.mapValues(\.propertyList), forKey: Key.rememberedApps)
  }
}
