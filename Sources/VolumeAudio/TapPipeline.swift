import CoreAudio
import Foundation
import Synchronization

/// Owns the Core Audio objects of one tap: the process tap, the private aggregate device and
/// the IOProc. Whatever was created is destroyed, in the right order, by `teardown()` or when
/// this object is released (RAII, SPEC 12.3).
///
/// Destruction order: stop the IOProc, destroy the IOProc, destroy the aggregate device,
/// destroy the tap.
final class TapPipeline: Sendable {
  private struct Resources {
    var tap = AudioProperty.unknown
    var aggregate = AudioProperty.unknown
    var procID: AudioDeviceIOProcID?
    var started = false
  }

  private let resources = Mutex(Resources())

  init() {}

  /// Creates the process tap.
  func createTap(_ description: CATapDescription) throws(AudioError) -> AudioObjectID {
    var tapID = AudioProperty.unknown
    try AudioError.check(
      AudioHardwareCreateProcessTap(description, &tapID), "create process tap")
    guard tapID != AudioProperty.unknown else {
      throw AudioError.unsupported("create process tap returned no object")
    }
    resources.withLock { $0.tap = tapID }
    return tapID
  }

  /// Creates the private aggregate device.
  func createAggregate(_ dictionary: [String: Any]) throws(AudioError) -> AudioObjectID {
    var aggregateID = AudioProperty.unknown
    try AudioError.check(
      AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregateID),
      "create aggregate device")
    guard aggregateID != AudioProperty.unknown else {
      throw AudioError.unsupported("create aggregate device returned no object")
    }
    resources.withLock { $0.aggregate = aggregateID }
    return aggregateID
  }

  /// Registers `proc` on the aggregate device and starts it. `client` must stay valid until
  /// `teardown()` returns.
  func startIO(proc: @escaping AudioDeviceIOProc, client: UnsafeMutableRawPointer?)
    throws(AudioError)
  {
    let aggregate = resources.withLock { $0.aggregate }
    guard aggregate != AudioProperty.unknown else {
      throw AudioError.unsupported("start IO without an aggregate device")
    }
    var procID: AudioDeviceIOProcID?
    try AudioError.check(
      AudioDeviceCreateIOProcID(aggregate, proc, client, &procID), "create IOProc")
    resources.withLock { $0.procID = procID }
    try AudioError.check(AudioDeviceStart(aggregate, procID), "start IOProc")
    resources.withLock { $0.started = true }
  }

  /// Destroys everything that exists. Idempotent and safe from any thread.
  func teardown() {
    let taken = resources.withLock { state -> Resources in
      defer { state = Resources() }
      return state
    }
    if taken.started, let procID = taken.procID {
      report(AudioDeviceStop(taken.aggregate, procID), "stop IOProc")
    }
    if let procID = taken.procID {
      report(AudioDeviceDestroyIOProcID(taken.aggregate, procID), "destroy IOProc")
    }
    if taken.aggregate != AudioProperty.unknown {
      report(AudioHardwareDestroyAggregateDevice(taken.aggregate), "destroy aggregate device")
    }
    if taken.tap != AudioProperty.unknown {
      report(AudioHardwareDestroyProcessTap(taken.tap), "destroy process tap")
    }
  }

  private func report(_ status: OSStatus, _ what: String) {
    guard status != noErr else { return }
    AudioLog.logger.warning(
      "teardown \(what, privacy: .public) failed: \(status, privacy: .public)")
  }

  deinit { teardown() }
}
