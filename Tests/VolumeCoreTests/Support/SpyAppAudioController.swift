import Synchronization

@testable import VolumeCore

/// Records what the domain asks the audio controller to do.
final class SpyAppAudioController: AppAudioController, Sendable {
  enum Call: Sendable, Equatable {
    case reconcile([DesiredAppAudio])
    case restoreAll
    case retry(String)
    case retryAll
  }

  private let recorded = Mutex<[Call]>([])

  var calls: [Call] { recorded.withLock { $0 } }

  var reconcileCalls: [[DesiredAppAudio]] {
    calls.compactMap { call in
      if case .reconcile(let desired) = call { return desired }
      return nil
    }
  }

  /// True when every reconcile call so far asked for no tap at all.
  var neverTapped: Bool { reconcileCalls.allSatisfy { $0.isEmpty } }

  /// True when `list` has entries and every one leaves the sound as it is: gain exactly 1, not
  /// muted, on the default output (the always-controlled taps of SPEC 4.2). An empty list
  /// (no tap at all) is not "unchanged".
  static func isUnchanged(_ list: [DesiredAppAudio], defaultUID: String = "speakers") -> Bool {
    !list.isEmpty && list.allSatisfy { isUnchanged($0, defaultUID: defaultUID) }
  }

  static func isUnchanged(_ entry: DesiredAppAudio, defaultUID: String = "speakers") -> Bool {
    entry.gain == 1 && !entry.muted && entry.targetDeviceUID == defaultUID
  }

  /// True when no reconcile call so far changed the sound of any app.
  var onlyUnchangedAudio: Bool {
    reconcileCalls.allSatisfy { $0.allSatisfy { Self.isUnchanged($0) } }
  }

  var restoreAllCount: Int { calls.filter { $0 == .restoreAll }.count }

  func reconcile(desired: [DesiredAppAudio]) async {
    recorded.withLock { $0.append(.reconcile(desired)) }
  }

  func restoreAll() async {
    recorded.withLock { $0.append(.restoreAll) }
  }

  func retry(appID: String) async {
    recorded.withLock { $0.append(.retry(appID)) }
  }

  func retryAll() async {
    recorded.withLock { $0.append(.retryAll) }
  }
}
