import Foundation
import Testing
import VolumeCore

@testable import VolumeSystem

private final class FakeController: AppServiceControlling, @unchecked Sendable {
  struct Failure: Error {}
  private let lock = NSLock()
  private var current: AppServiceState
  private var registerCalls = 0
  private var unregisterCalls = 0
  private var settingsCalls = 0
  var failing = false

  init(_ state: AppServiceState) { current = state }

  var counts: (register: Int, unregister: Int, settings: Int) {
    lock.withLock { (registerCalls, unregisterCalls, settingsCalls) }
  }
  func state() -> AppServiceState { lock.withLock { current } }
  func register() throws {
    try lock.withLock {
      registerCalls += 1
      if failing { throw Failure() }
      current = .enabled
    }
  }
  func unregister() throws {
    try lock.withLock {
      unregisterCalls += 1
      if failing { throw Failure() }
      current = .notRegistered
    }
  }
  func openSettings() { lock.withLock { settingsCalls += 1 } }
}

@Suite("SMAppLoginItemService", .timeLimit(.minutes(1)))
struct LoginItemServiceTests {
  @Test(arguments: [
    (AppServiceState.enabled, LoginItemStatus.enabled),
    (.notRegistered, .disabled),
    (.requiresApproval, .requiresApproval),
    (.notFound, .notFound),
  ])
  func mapsEveryStatus(state: AppServiceState, expected: LoginItemStatus) {
    let service = SMAppLoginItemService(controller: FakeController(state))
    #expect(service.status() == expected)
  }

  @Test func registersOnlyOnExplicitEnable() throws {
    let fake = FakeController(.notRegistered)
    let service = SMAppLoginItemService(controller: fake)
    #expect(service.status() == .disabled)
    #expect(fake.counts.register == 0)
    try service.setEnabled(true)
    #expect(fake.counts.register == 1)
    #expect(service.status() == .enabled)
  }

  @Test func enablingAnAlreadyEnabledItemDoesNothing() throws {
    let fake = FakeController(.enabled)
    try SMAppLoginItemService(controller: fake).setEnabled(true)
    #expect(fake.counts.register == 0)
  }

  @Test func disablingUnregistersAndIsIdempotent() throws {
    let fake = FakeController(.enabled)
    let service = SMAppLoginItemService(controller: fake)
    try service.setEnabled(false)
    try service.setEnabled(false)
    #expect(fake.counts.unregister == 1)
    #expect(service.status() == .disabled)
  }

  @Test func failuresAreTyped() {
    let fake = FakeController(.notRegistered)
    fake.failing = true
    let service = SMAppLoginItemService(controller: fake)
    #expect(throws: LoginItemError.self) { try service.setEnabled(true) }
    let enabled = FakeController(.enabled)
    enabled.failing = true
    #expect(throws: LoginItemError.self) {
      try SMAppLoginItemService(controller: enabled).setEnabled(false)
    }
  }

  @Test func opensSettingsThroughTheController() {
    let fake = FakeController(.requiresApproval)
    SMAppLoginItemService(controller: fake).openLoginItemsSettings()
    #expect(fake.counts.settings == 1)
  }
}
