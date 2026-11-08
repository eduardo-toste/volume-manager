import Testing

@testable import VolumeCore

@MainActor
@Suite("Models and doubles")
struct ModelTests {
  @Test func outputDeviceSanitizesSystemText() {
    let device = OutputDevice(
      id: 3, uid: "uid\u{202E}1", name: "AirPods\u{0007} Pro " + String(repeating: "x", count: 400))
    #expect(device.uid == "uid1")
    #expect(device.name.count == 200)
    #expect(device.hasVolumeControl)
    #expect(device.kind == .other)
    #expect(OutputDeviceKind.allCases.count == 7)
  }

  @Test func appAudioStateClampsAndDefaults() {
    #expect(
      AppAudioState.default == AppAudioState(volume: 1, muted: false, preferredOutputUID: nil))
    #expect(AppAudioState(volume: .nan).volume == 1)
    #expect(AppAudioState(volume: 9).volume == 1)
    #expect(AppAudioState(volume: -1).volume == 0)
  }

  @Test func masterStateClamps() {
    #expect(MasterOutputState(volume: 4, isMuted: false).volume == 1)
    #expect(MasterOutputState(volume: .nan, isMuted: true).volume == 1)
  }

  @Test func rememberedAppConversions() {
    let state = AppAudioState(volume: 0.2, muted: true, preferredOutputUID: "u")
    let record = RememberedApp(state)
    #expect(record.state == state)
    #expect(RememberedApp(volume: 3, muted: false, outputUID: nil).volume == 1)
    let list = record.propertyList
    #expect(list["volume"] as? Double == 0.2)
    #expect(list["outputUID"] as? String == "u")
    #expect(RememberedApp(volume: 1, muted: false, outputUID: nil).propertyList["outputUID"] == nil)
    #expect(RememberedApp(validating: list) == record)
    #expect(RememberedApp(validating: 5) == nil)
  }

  @Test func preferenceValidationRules() {
    #expect(PreferenceValidation.bool(true) == true)
    #expect(PreferenceValidation.bool(1) == nil)
    #expect(PreferenceValidation.bool(nil) == nil)
    #expect(PreferenceValidation.volume(0.5) == 0.5)
    #expect(PreferenceValidation.volume(false) == nil)
    #expect(PreferenceValidation.volume(1.5) == nil)
    #expect(PreferenceValidation.integer(5) == 5)
    #expect(PreferenceValidation.integer(nil) == nil)
    #expect(PreferenceValidation.string(String(repeating: "a", count: 201)) == nil)
    #expect(PreferenceValidation.uid("") == nil)
    #expect(PreferenceValidation.uid("ok") == "ok")
    #expect(PreferenceValidation.uid("a\tb") == nil)
  }

  @Test func fakeServicesBehaveAsContracts() async throws {
    let login = FakeLoginItemService()
    #expect(login.status() == .disabled)
    try login.setEnabled(true)
    #expect(login.status() == .enabled)
    login.openLoginItemsSettings()
    #expect(login.openedSettingsCount == 1)

    let permission = FakePermissionService()
    #expect(await permission.currentStatus() == .notDetermined)
    #expect(await permission.request() == .granted)
    permission.openPrivacySettings()
  }

  @Test func fakeClockWakesSleepersInOrder() async {
    let clock = FakeClock()
    let done = Task { try await clock.sleep(for: .seconds(2)) }
    #expect(await eventually { clock.sleeperCount == 1 })
    clock.advance(by: .seconds(1))
    await Task.yield()
    #expect(clock.sleeperCount == 1)
    clock.advance(by: .seconds(1))
    _ = try? await done.value
    #expect(clock.sleeperCount == 0)
    let cancelled = Task { try await clock.sleep(for: .seconds(100)) }
    #expect(await eventually { clock.sleeperCount == 1 })
    cancelled.cancel()
    let result = await cancelled.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(clock.now.offset == .seconds(2))
    #expect(clock.minimumResolution == .zero)
    let already = clock.now.advanced(by: .seconds(-1))
    try? await clock.sleep(until: already, tolerance: nil)
    #expect(clock.now.duration(to: clock.now.advanced(by: .seconds(1))) == .seconds(1))
  }
}
