import Testing

@testable import VolumeCore

@MainActor
@Suite("M5: welcome window and login item", .timeLimit(.minutes(1)))
struct WelcomeAndLoginItemTests {
  private let harness: MixerHarness
  private let login = FakeLoginItemService()
  private let loginItem: LoginItemModel
  private let welcome: WelcomeModel

  init(permission: AudioPermissionStatus = .notDetermined) {
    harness = MixerHarness(permission: permission)
    loginItem = LoginItemModel(service: login)
    welcome = WelcomeModel(
      settings: harness.settings, loginItem: loginItem, store: harness.store,
      permission: harness.permission)
  }

  // MARK: First run

  @Test func firstRunNeedsTheWelcomeAndStartMarksItDoneForGood() {
    #expect(!harness.settings.onboardingCompleted)
    welcome.start()
    #expect(harness.settings.onboardingCompleted)
    // A second launch reads the stored flag: no welcome.
    let second = SettingsModel(store: harness.preferences, clock: harness.clock)
    #expect(second.onboardingCompleted)
  }

  @Test func startRegistersTheLoginItemOnlyWithTheToggleOn() {
    #expect(welcome.launchAtLogin)
    welcome.start()
    #expect(login.changes == [true])
    #expect(loginItem.isOn)
  }

  @Test func startWithTheToggleOffRegistersNothing() {
    welcome.launchAtLogin = false
    welcome.start()
    #expect(login.status() == .disabled)
    #expect(!login.changes.contains(true))
    #expect(harness.settings.onboardingCompleted)
  }

  // MARK: Permission row

  @Test func allowGrantsAndStoresTheMark() async {
    harness.access.answer = .granted
    #expect(welcome.access == .notAsked)
    await welcome.allow()
    #expect(welcome.access == .allowed)
    #expect(harness.permission.status == .granted)
    #expect(harness.settings.audioPermissionConfirmed)
    #expect(harness.access.requests == 1)
  }

  @Test func allowDeniedKeepsTheMarkOffAndTheNextClickOpensSystemSettings() async {
    harness.access.answer = .denied
    await welcome.allow()
    #expect(welcome.access == .denied)
    #expect(!harness.settings.audioPermissionConfirmed)
    await welcome.allow()
    #expect(harness.access.requests == 1)
    #expect(harness.access.opened == 1)
  }

  @Test func inconclusiveCheckStoresNothingAndMayBeTriedAgain() async {
    harness.access.conclusive = false
    await welcome.allow()
    #expect(welcome.access == .inconclusive)
    #expect(!harness.settings.audioPermissionConfirmed)
    harness.access.conclusive = true
    harness.access.answer = .granted
    await welcome.allow()
    #expect(welcome.access == .allowed)
  }

  @Test func deniedRowLeavesDeniedWhenThePermissionChangesWithoutAskingAgain() async {
    harness.access.answer = .denied
    await welcome.allow()
    #expect(welcome.access == .denied)
    welcome.refreshAccess()
    #expect(welcome.access == .denied, "still denied: nothing changed")
    // Another check (the popover's) found the permission granted later.
    harness.access.answer = .granted
    await harness.permission.refresh(onlyIfDenied: true)
    welcome.refreshAccess()
    #expect(welcome.access == .allowed)
    #expect(harness.access.requests == 2, "only the monitor's own check ran, not the window's")
  }

  @Test func alreadyGrantedThisSessionShowsAllowed() {
    let granted = WelcomeAndLoginItemTests(permission: .granted)
    #expect(granted.welcome.access == .allowed)
  }

  // MARK: Login item

  @Test func loginItemShowsTheRealStateWhenItIsReadAgain() {
    #expect(!loginItem.isOn)
    login.setStatus(.enabled)
    #expect(!loginItem.isOn, "not read yet")
    loginItem.refresh()
    #expect(loginItem.isOn)
    // The user turned it off in System Settings.
    login.setStatus(.disabled)
    loginItem.refresh()
    #expect(!loginItem.isOn)
  }

  @Test func requiresApprovalIsOnAndAsksForApproval() {
    login.setStatus(.requiresApproval)
    loginItem.refresh()
    #expect(loginItem.isOn)
    #expect(loginItem.needsApproval)
    loginItem.openSettings()
    #expect(login.openedSettingsCount == 1)
  }

  @Test func notFoundIsOff() {
    login.setStatus(.notFound)
    loginItem.refresh()
    #expect(!loginItem.isOn)
    #expect(!loginItem.needsApproval)
  }

  @Test func refusedChangeIsReportedAndTheRealStateStays() {
    login.failChanges(true)
    loginItem.setEnabled(true)
    #expect(loginItem.lastChangeFailed)
    #expect(!loginItem.isOn)
    login.failChanges(false)
    loginItem.setEnabled(true)
    #expect(!loginItem.lastChangeFailed)
    #expect(loginItem.isOn)
  }
}
