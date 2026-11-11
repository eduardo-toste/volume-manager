import Synchronization
import Testing

@testable import VolumeCore

/// Security review of M6: the waiters of `PermissionMonitor.refresh` are resumed exactly once,
/// a cancelled waiter does not leak, and a check that is cut short never reaches a waiter as a
/// denial.
@MainActor
@Suite("Security M6", .timeLimit(.minutes(1)))
struct SecurityM6Tests {
  @Test func manyWaitersAreEachResumedOnceWithTheSameResult() async {
    let gate = HeldPermissionService(answer: .granted)
    let monitor = PermissionMonitor(service: gate, onGranted: {})
    let first = Task { await monitor.refresh(onlyIfDenied: false) }
    #expect(await eventually { gate.requests == 1 })
    let waiters = (0..<8).map { _ in Task { await monitor.refresh(onlyIfDenied: false) } }
    for _ in 0..<50 { await Task.yield() }
    gate.release()
    #expect(await first.value == .granted)
    for waiter in waiters { #expect(await waiter.value == .granted) }
    #expect(gate.requests == 1, "waiters never start their own probe")
    // The monitor is idle again: a new call runs a new check.
    #expect(await monitor.refresh(onlyIfDenied: false) == .granted)
    #expect(gate.requests == 2)
  }

  @Test func aCancelledWaiterStillEndsWhenTheRunningCheckEnds() async {
    let gate = HeldPermissionService(answer: .granted)
    let monitor = PermissionMonitor(service: gate, onGranted: {})
    let first = Task { await monitor.refresh(onlyIfDenied: false) }
    #expect(await eventually { gate.requests == 1 })
    let waiter = Task { await monitor.refresh(onlyIfDenied: false, userAction: true) }
    for _ in 0..<50 { await Task.yield() }
    waiter.cancel()
    gate.release()
    _ = await first.value
    #expect(await waiter.value == .granted)
    #expect(gate.requests == 1)
  }

  @Test func aCancelledRunningCheckNeverHandsADenialToItsWaiters() async {
    let gate = HeldPermissionService(answer: .denied)
    let monitor = PermissionMonitor(service: gate, onGranted: {})
    let first = Task { await monitor.refresh(onlyIfDenied: false) }
    #expect(await eventually { gate.requests == 1 })
    let waiter = Task { await monitor.refresh(onlyIfDenied: false) }
    for _ in 0..<50 { await Task.yield() }
    first.cancel()
    gate.release()
    #expect(await first.value == .notDetermined)
    #expect(await waiter.value == .notDetermined)
    #expect(monitor.status != .denied)
  }
}

/// Holds the first request until `release()`; every request answers `answer`.
private final class HeldPermissionService: PermissionService, Sendable {
  private let state = Mutex(
    (
      answer: AudioPermissionStatus.notDetermined, requests: 0,
      gate: CheckedContinuation<Void, Never>?.none, released: false
    ))

  init(answer: AudioPermissionStatus) { state.withLock { $0.answer = answer } }
  var requests: Int { state.withLock { $0.requests } }

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
      return state.requests
    }
    if number == 1 {
      await withCheckedContinuation { continuation in
        let resumeNow = state.withLock { state -> Bool in
          if state.released { return true }
          state.gate = continuation
          return false
        }
        if resumeNow { continuation.resume() }
      }
    }
    return state.withLock { $0.answer }
  }

  func openPrivacySettings() {}
}
