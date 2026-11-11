import CoreAudio
import Foundation
import Synchronization

/// Owns the Core Audio objects of one tap: the process tap, the private aggregate device and
/// the IOProc. Whatever was created and is still ours (it answers with the UID it was created
/// with, or is found by that UID) is destroyed, in the right order, by `teardown()` or when this
/// object is released (RAII, SPEC 12.3). Objects whose IDs went stale are never touched.
///
/// Destruction order: stop the IOProc, destroy the IOProc, destroy the aggregate device,
/// destroy the tap.
final class TapPipeline: Sendable {
  private struct Resources {
    var tap = AudioProperty.unknown
    var aggregate = AudioProperty.unknown
    var procID: AudioDeviceIOProcID?
    var started = false
    /// The identity each object was created with: only an object that still answers with it
    /// is ours (S21-B1/B2).
    var tapUID = ""
    var aggregateUID = ""
  }

  private let resources = Mutex(Resources())

  init() {}

  /// Creates the process tap.
  func createTap(_ description: CATapDescription) throws(AudioError) -> AudioObjectID {
    var tapID = AudioProperty.unknown
    try AudioError.check(
      AudioHardwareCreateProcessTap(description, &tapID), "create process tap",
      stage: .createTap)
    guard tapID != AudioProperty.unknown else {
      throw AudioError.unsupported(
        "create process tap returned no object", stage: .createTap)
    }
    resources.withLock {
      $0.tap = tapID
      $0.tapUID = description.uuid.uuidString
    }
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
    resources.withLock {
      $0.aggregate = aggregateID
      $0.aggregateUID = dictionary[kAudioAggregateDeviceUIDKey] as? String ?? ""
    }
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

  /// True when the object still answers with the identity it was created with. After a
  /// `coreaudiod` restart an old ID is dead (no answer) or names someone else's object (another
  /// answer), and must not be destroyed (SPEC 4.6, findings M-2, S21-B1, S21-B2).
  static func isOurs(found: String?, expected: String) -> Bool {
    guard !expected.isEmpty, let found else { return false }
    return found.caseInsensitiveCompare(expected) == .orderedSame
  }

  /// The ID to destroy for an object created with `expected` as its UID, or `nil` to leave it
  /// alone. `id` is used when it still answers with that UID; otherwise the server is asked
  /// which object has that UID (`translate`, `unknown` when none), so a live object of ours is
  /// never left behind by a failed read (SPEC 4.6: no app stays muted), while a stale ID that
  /// names someone else's object is never destroyed (findings M-2, S6-M1).
  static func resolve(
    id: AudioObjectID, expected: String, read: (AudioObjectID) -> String?,
    translate: (String) -> AudioObjectID
  ) -> AudioObjectID? {
    if isOurs(found: read(id), expected: expected) { return id }
    guard !expected.isEmpty else { return nil }
    let found = translate(expected)
    return found == AudioProperty.unknown ? nil : found
  }

  /// Destroys everything that exists and is still ours (see `resolve`). Idempotent and safe
  /// from any thread. Returns false when something was left alone or a Core Audio call failed,
  /// which means the IOProc may still be running somewhere (see `teardown(keeping:)`).
  @discardableResult
  func teardown() -> Bool {
    let taken = resources.withLock { state -> Resources in
      defer { state = Resources() }
      return state
    }
    var allOurs = true
    if taken.aggregate != AudioProperty.unknown {
      if let aggregate = Self.resolve(
        id: taken.aggregate, expected: taken.aggregateUID,
        read: {
          try? AudioProperty.string($0, AudioProperty.address(kAudioDevicePropertyDeviceUID))
        },
        translate: { Self.translate(kAudioHardwarePropertyTranslateUIDToDevice, uid: $0) })
      {
        if taken.started, let procID = taken.procID {
          allOurs = report(AudioDeviceStop(aggregate, procID), "stop IOProc") && allOurs
        }
        if let procID = taken.procID {
          allOurs =
            report(AudioDeviceDestroyIOProcID(aggregate, procID), "destroy IOProc") && allOurs
        }
        allOurs =
          report(AudioHardwareDestroyAggregateDevice(aggregate), "destroy aggregate device")
          && allOurs
      } else {
        AudioLog.logger.notice(
          "teardown: aggregate \(taken.aggregate, privacy: .public) left alone, identity not confirmed"
        )
        allOurs = false
      }
    }
    if taken.tap != AudioProperty.unknown {
      if let tap = Self.resolve(
        id: taken.tap, expected: taken.tapUID,
        read: { try? AudioProperty.string($0, AudioProperty.address(kAudioTapPropertyUID)) },
        translate: { Self.translate(kAudioHardwarePropertyTranslateUIDToTap, uid: $0) })
      {
        allOurs = report(AudioHardwareDestroyProcessTap(tap), "destroy process tap") && allOurs
      } else {
        AudioLog.logger.notice(
          "teardown: tap \(taken.tap, privacy: .public) left alone, identity not confirmed")
        allOurs = false
      }
    }
    return allOurs
  }

  /// The object the server knows by this UID (`unknown` when there is none or the call fails).
  static func translate(_ selector: AudioObjectPropertySelector, uid: String)
    -> AudioObjectID
  {
    var address = AudioProperty.address(selector)
    var qualifier = uid as CFString
    var object = AudioProperty.unknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &qualifier) {
      AudioObjectGetPropertyData(
        AudioProperty.system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &object)
    }
    return status == noErr ? object : AudioProperty.unknown
  }

  /// Like `teardown()`, but if an object was left alone its IOProc may still call into
  /// `client`, which is then kept alive forever (a few bytes) instead of freed.
  func teardown(keeping client: AnyObject) {
    if !teardown() { _ = Unmanaged.passRetained(client) }
  }

  @discardableResult
  private func report(_ status: OSStatus, _ what: String) -> Bool {
    guard status != noErr else { return true }
    AudioLog.logger.warning(
      "teardown \(what, privacy: .public) failed: \(status, privacy: .public)")
    return false
  }

  deinit { teardown() }
}
