import Testing

@testable import VolumeCore

@Suite("QA M5.1: welcome permission row", .timeLimit(.minutes(1)))
@MainActor
struct QAM51WelcomeTests {
  /// The click lands while another check runs and that check finds the permission granted: the
  /// row shows it as allowed (the new rule only stops a stale "not asked" from staying).
  @Test func clickDuringAnotherCheckThatGrantsShowsAllowed() async {
    let harness = MixerHarness(permission: .notDetermined)
    let welcome = WelcomeModel(
      settings: harness.settings, loginItem: LoginItemModel(service: FakeLoginItemService()),
      store: harness.store, permission: harness.permission)
    harness.access.answer = .granted
    let other = Task { await harness.permission.refresh(onlyIfDenied: false) }
    await Task.yield()
    await welcome.allow()
    _ = await other.value
    // Whether the other check ended before the click depends on scheduling; when the window
    // becomes active again the row follows the monitor either way.
    welcome.refreshAccess()
    #expect(welcome.access == .allowed)
  }
}
