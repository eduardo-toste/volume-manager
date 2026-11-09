import Testing

@testable import VolumeCore

// QA M5: edge cases of the welcome and login item flows, from fakes only.
@MainActor
@Suite("QA M5: welcome and settings edge cases", .timeLimit(.minutes(1)))
struct QAM5Tests {
  private func make(
    preferences: [String: Any] = [:], permission: AudioPermissionStatus = .notDetermined
  ) -> (MixerHarness, FakeLoginItemService, LoginItemModel, WelcomeModel) {
    let harness = MixerHarness(preferences: preferences, permission: permission)
    let login = FakeLoginItemService()
    let item = LoginItemModel(service: login)
    let welcome = WelcomeModel(
      settings: harness.settings, loginItem: item, store: harness.store,
      permission: harness.permission)
    return (harness, login, item, welcome)
  }

  @Test func startStillCompletesWhenTheSystemRefusesTheLoginItem() {
    let (harness, login, item, welcome) = make()
    login.failChanges(true)
    welcome.start()
    #expect(harness.settings.onboardingCompleted, "a refusal must not trap the user in the welcome")
    #expect(item.lastChangeFailed)
  }

  @Test func doubleClickOnStartRegistersNoMoreThanTheToggleAsks() {
    let (harness, login, _, welcome) = make()
    welcome.start()
    welcome.start()
    #expect(login.status() == .enabled)
    #expect(login.changes.allSatisfy { $0 })
    #expect(harness.settings.onboardingCompleted)
  }

  @Test func corruptOnboardingFlagMeansWelcomeAgainNotACrash() {
    for bad: Any in ["yes", 7, [1, 2], ["a": 1], Double.nan] {
      let (harness, _, _, _) = make(preferences: ["onboardingCompleted": bad])
      #expect(!harness.settings.onboardingCompleted)
    }
  }

  @Test func overlappingAllowClicksAskOnce() async {
    let (harness, _, _, welcome) = make()
    harness.access.answer = .granted
    async let first: Void = welcome.allow()
    async let second: Void = welcome.allow()
    _ = await (first, second)
    #expect(harness.access.requests == 1)
    #expect(welcome.access == .allowed)
    #expect(!welcome.isAsking)
  }

  @Test func deniedNeverStoresTheMarkAndNeverBreaksAudio() async {
    let (harness, _, _, welcome) = make(preferences: ["audioPermissionConfirmed": true])
    harness.access.answer = .denied
    await welcome.allow()
    #expect(welcome.access == .denied)
    #expect(!harness.settings.audioPermissionConfirmed, "a real denial clears the stale mark")
  }

  @Test func startDoesNotTouchThePermissionMark() {
    let (harness, _, _, welcome) = make()
    welcome.start()
    #expect(!harness.settings.audioPermissionConfirmed)
    #expect(harness.access.requests == 0)
  }

  @Test func refreshAfterApprovalGrantedElsewhereFollowsTheSystem() {
    let (_, login, item, _) = make()
    login.setStatus(.requiresApproval)
    item.refresh()
    #expect(item.needsApproval)
    login.setStatus(.enabled)
    item.refresh()
    #expect(!item.needsApproval)
  }
}
