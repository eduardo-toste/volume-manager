import Observation

/// Every user preference of SPEC 3.3, with safe defaults, validated loading and debounced
/// saving.
@MainActor
@Observable
public final class SettingsModel {
  /// Storage keys.
  enum Key {
    static let rememberVolumes = "rememberVolumes"
    static let volumeStep = "volumeStepPercent"
    static let onboardingCompleted = "onboardingCompleted"
    static let permissionConfirmed = "audioPermissionConfirmed"
    static let permissionBuild = "audioPermissionBuild"
    static let rememberedApps = "rememberedApps"
  }

  /// Time without changes before the preferences are written (SPEC 12.4).
  public static let saveDelay: Duration = .milliseconds(500)

  /// Remember the volume of each app. Default on.
  public var rememberVolumes = true { didSet { changed(oldValue != rememberVolumes) } }
  /// Slider increment. Default 5%.
  public var volumeStep = VolumeStep.five { didSet { changed(oldValue != volumeStep) } }
  /// True once the welcome window has been dealt with.
  public var onboardingCompleted = false {
    didSet { changed(oldValue != onboardingCompleted) }
  }
  /// True once the audio permission was confirmed as granted on this Mac. It lets the app
  /// verify the permission at launch without showing the system prompt (the user already
  /// decided). Cleared when a check the user asked for ("Permitir…") finds it denied
  /// (SPEC 5), and at launch when the app build differs from the one that confirmed it: an
  /// ad hoc signed update is seen as a new app by macOS (SPEC 13.2).
  public var audioPermissionConfirmed = false {
    didSet { changed(oldValue != audioPermissionConfirmed) }
  }
  /// Remembered apps by bundle ID.
  public private(set) var rememberedApps: [String: RememberedApp] = [:]

  @ObservationIgnored private let store: any PreferencesStore
  @ObservationIgnored private let clock: AppClock
  /// Build (`CFBundleVersion`) of this run; stored with the permission mark.
  @ObservationIgnored private let build: String
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var observers: [@MainActor () -> Void] = []
  @ObservationIgnored private var isLoading = true

  /// Loads and validates the stored preferences. Invalid values become the defaults.
  /// `build` is the running app's `CFBundleVersion`.
  public init(store: any PreferencesStore, clock: AppClock, build: String) {
    self.store = store
    self.clock = clock
    self.build = build
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
    rememberVolumes = PreferenceValidation.bool(store.object(forKey: Key.rememberVolumes)) ?? true
    onboardingCompleted =
      PreferenceValidation.bool(store.object(forKey: Key.onboardingCompleted)) ?? false
    // The mark only counts for the build that confirmed it (missing or invalid build: no mark).
    audioPermissionConfirmed =
      (PreferenceValidation.bool(store.object(forKey: Key.permissionConfirmed)) ?? false)
      && PreferenceValidation.string(store.object(forKey: Key.permissionBuild)) == build
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
    store.set(rememberVolumes, forKey: Key.rememberVolumes)
    store.set(volumeStep.rawValue, forKey: Key.volumeStep)
    store.set(onboardingCompleted, forKey: Key.onboardingCompleted)
    store.set(audioPermissionConfirmed, forKey: Key.permissionConfirmed)
    store.set(audioPermissionConfirmed ? build : nil, forKey: Key.permissionBuild)
    store.set(rememberedApps.mapValues(\.propertyList), forKey: Key.rememberedApps)
  }
}
