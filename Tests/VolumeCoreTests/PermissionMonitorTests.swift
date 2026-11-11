import Synchronization
import Testing

@testable import VolumeCore

@MainActor
@Suite("PermissionMonitor", .timeLimit(.minutes(1)))
struct PermissionMonitorTests {
  private let service = ScriptedPermissionService()

  @Test func startsUndecidedAndNeverDenied() {
    let monitor = PermissionMonitor(service: service, onGranted: {})
    #expect(monitor.status == .notDetermined)
    #expect(monitor.status != .denied)
  }

  @Test func openingThePopoverDoesNotCheckWhileUndecidedOrGranted() async {
    let monitor = PermissionMonitor(service: service, onGranted: {})
    await monitor.refresh(onlyIfDenied: true)
    #expect(service.requests == 0)
    service.answer = .granted
    await monitor.refresh(onlyIfDenied: false)
    await monitor.refresh(onlyIfDenied: true)
    #expect(service.requests == 1)
  }

  @Test func silenceThatTheCheckConfirmsMarksDenied() async {
    let monitor = PermissionMonitor(service: service, onGranted: {})
    service.answer = .denied
    await monitor.refresh(onlyIfDenied: false)
    #expect(monitor.status == .denied)
  }

  @Test func indeterminateCheckIsNotDenied() async {
    let monitor = PermissionMonitor(service: service, onGranted: {})
    service.answer = .notDetermined
    await monitor.refresh(onlyIfDenied: false)
    #expect(monitor.status != .denied)
  }

  @Test func grantAfterDenialRunsOnGrantedOnce() async {
    var count = 0
    let monitor = PermissionMonitor(service: service, onGranted: { count += 1 })
    service.answer = .denied
    await monitor.refresh(onlyIfDenied: false)
    service.answer = .granted
    await monitor.refresh(onlyIfDenied: true)
    await monitor.refresh(onlyIfDenied: true)
    #expect(monitor.status == .granted)
    #expect(count == 1)
  }

  @Test func stillDeniedKeepsCheckingOnEachOpen() async {
    let monitor = PermissionMonitor(service: service, onGranted: {})
    service.answer = .denied
    await monitor.refresh(onlyIfDenied: false)
    await monitor.refresh(onlyIfDenied: true)
    #expect(service.requests == 2)
    #expect(monitor.status == .denied)
  }

  @Test func opensThePrivacyPane() {
    let monitor = PermissionMonitor(service: service, onGranted: {})
    monitor.openPrivacySettings()
    #expect(service.opened == 1)
  }

  // M6: "Permitir…" during the automatic check at launch waits for it.

  @Test func aCheckAskedDuringARunningOneWaitsForItsResult() async {
    let gated = GatedPermissionService(first: .granted)
    let monitor = PermissionMonitor(service: gated, onGranted: {})
    async let automatic = monitor.refresh(onlyIfDenied: false)
    #expect(await eventually { gated.requests == 1 })
    async let click = monitor.refresh(onlyIfDenied: false, userAction: true)
    for _ in 0..<50 { await Task.yield() }
    gated.release()
    let results = await [automatic, click]
    #expect(results == [.granted, .granted], "the click gets the answer, not nil")
    #expect(gated.requests == 1, "one probe only")
    #expect(monitor.status == .granted)
  }

  @Test func aUserActionAfterAnInconclusiveRunningCheckRunsItsOwn() async {
    let gated = GatedPermissionService(first: .notDetermined)
    let monitor = PermissionMonitor(service: gated, onGranted: {})
    async let automatic = monitor.refresh(onlyIfDenied: false)
    #expect(await eventually { gated.requests == 1 })
    async let click = monitor.refresh(onlyIfDenied: false, userAction: true)
    for _ in 0..<50 { await Task.yield() }
    gated.release()
    #expect(await automatic == .notDetermined)
    #expect(await click == .granted)
    #expect(gated.requests == 2)
    #expect(gated.userActions == [false, true])
  }

  @Test func onlyIfDeniedStillReturnsNilWhenNotDenied() async {
    let gated = GatedPermissionService(first: .granted)
    let monitor = PermissionMonitor(service: gated, onGranted: {})
    async let automatic = monitor.refresh(onlyIfDenied: false)
    #expect(await eventually { gated.requests == 1 })
    #expect(await monitor.refresh(onlyIfDenied: true) == nil)
    gated.release()
    _ = await automatic
  }
}

/// The first request waits until `release()`; later ones answer `.granted` at once.
private final class GatedPermissionService: PermissionService, Sendable {
  private let state = Mutex(
    (
      first: AudioPermissionStatus.notDetermined, requests: 0, userActions: [Bool](),
      gate: CheckedContinuation<Void, Never>?.none, released: false
    ))

  init(first: AudioPermissionStatus) { state.withLock { $0.first = first } }
  var requests: Int { state.withLock { $0.requests } }
  var userActions: [Bool] { state.withLock { $0.userActions } }

  func release() {
    let gate = state.withLock { state -> CheckedContinuation<Void, Never>? in
      state.released = true
      defer { state.gate = nil }
      return state.gate
    }
    gate?.resume()
  }

  func request(userAction: Bool) async -> AudioPermissionStatus {
    let number = state.withLock { state -> Int in
      state.requests += 1
      state.userActions.append(userAction)
      return state.requests
    }
    guard number == 1 else { return .granted }
    await withCheckedContinuation { continuation in
      let resumeNow = state.withLock { state -> Bool in
        if state.released { return true }
        state.gate = continuation
        return false
      }
      if resumeNow { continuation.resume() }
    }
    return state.withLock { $0.first }
  }

  func openPrivacySettings() {}
}
